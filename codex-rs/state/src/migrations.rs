use std::borrow::Cow;
use std::collections::HashSet;

use sqlx::AssertSqlSafe;
use sqlx::Row;
use sqlx::SqlSafeStr;
use sqlx::SqlitePool;
use sqlx::migrate::Migration;
use sqlx::migrate::MigrationType;
use sqlx::migrate::Migrator;

use crate::telemetry::DbKind;

pub(crate) static STATE_MIGRATOR: Migrator = sqlx::migrate!("./migrations");
pub(crate) static LOGS_MIGRATOR: Migrator = sqlx::migrate!("./logs_migrations");
pub(crate) static GOALS_MIGRATOR: Migrator = sqlx::migrate!("./goals_migrations");
pub(crate) static MEMORIES_MIGRATOR: Migrator = sqlx::migrate!("./memory_migrations");
pub(crate) static QUEUE_MIGRATOR: Migrator = sqlx::migrate!("./queue_migrations");
pub(crate) static THREAD_HISTORY_MIGRATOR: Migrator = sqlx::migrate!("./thread_history_migrations");

/// Normalize the line endings of a migration's SQL.
///
/// Git rewrites LF into CRLF when `core.autocrlf` is enabled, which is the
/// default on Windows. sqlx derives a migration's checksum from the raw bytes
/// of the migration file, so two builds of the same commit embed different
/// checksums for the same migration and sqlx then refuses to open a database
/// that the other build migrated with "migration N was previously applied but
/// has been modified". Normalizing the SQL before the checksum is computed
/// keeps the checksum identical for every build of a given commit.
fn canonical_sql(sql: &str) -> String {
    sql.replace("\r\n", "\n")
}

/// Compute the checksum sqlx records for a migration with the given SQL.
///
/// `sqlx::migrate::checksum` is not re-exported by the `sqlx` crate, but
/// `Migration::new` computes the same SHA-384 digest over the SQL text.
fn migration_checksum(sql: &str) -> Vec<u8> {
    Migration::new(
        0,
        Cow::Borrowed(""),
        MigrationType::Simple,
        AssertSqlSafe(sql.to_string()).into_sql_str(),
        false,
    )
    .checksum
    .into_owned()
}

/// Return the checksums that describe the same migration as `sql` when only
/// the line endings differ.
fn line_ending_equivalent_checksums(sql: &str) -> HashSet<Vec<u8>> {
    let canonical = canonical_sql(sql);
    let mut checksums = HashSet::new();
    checksums.insert(migration_checksum(&canonical));
    let crlf = canonical.replace('\n', "\r\n");
    if crlf != canonical {
        checksums.insert(migration_checksum(&crlf));
    }
    checksums
}

/// Rebuild a migrator so that every embedded migration uses LF line endings
/// and therefore carries the same checksum on every platform.
fn canonical_migrator(base: &Migrator) -> Migrator {
    let migrations = base
        .migrations
        .iter()
        .map(|migration| {
            let sql = canonical_sql(migration.sql.as_str());
            Migration::new(
                migration.version,
                migration.description.clone(),
                migration.migration_type,
                AssertSqlSafe(sql).into_sql_str(),
                migration.no_tx,
            )
        })
        .collect::<Vec<_>>();
    Migrator {
        migrations: Cow::Owned(migrations),
        ignore_missing: base.ignore_missing,
        locking: base.locking,
        no_tx: base.no_tx,
        table_name: base.table_name.clone(),
        create_schemas: base.create_schemas.clone(),
    }
}

/// Build the migrator that the runtime uses to open the local databases.
///
/// The embedded migrations are canonicalized so that their checksums do not
/// depend on the line endings of the build tree. `ignore_missing` allows an
/// older Codex binary to open a database that has already been migrated by a
/// newer binary running in parallel: applied migration versions that are newer
/// than the embedded migration set are ignored, while known migration versions
/// are still validated by checksum.
fn runtime_migrator(base: &'static Migrator) -> Migrator {
    let mut migrator = canonical_migrator(base);
    migrator.ignore_missing = true;
    migrator
}

pub(crate) fn runtime_state_migrator() -> Migrator {
    runtime_migrator(&STATE_MIGRATOR)
}

pub(crate) fn runtime_logs_migrator() -> Migrator {
    runtime_migrator(&LOGS_MIGRATOR)
}

pub(crate) fn runtime_goals_migrator() -> Migrator {
    runtime_migrator(&GOALS_MIGRATOR)
}

pub(crate) fn runtime_memories_migrator() -> Migrator {
    runtime_migrator(&MEMORIES_MIGRATOR)
}

pub(crate) fn runtime_queue_migrator() -> Migrator {
    runtime_migrator(&QUEUE_MIGRATOR)
}

// The paginated history projector will call this when it takes ownership of opening the database.
pub(crate) fn runtime_thread_history_migrator() -> Migrator {
    runtime_migrator(&THREAD_HISTORY_MIGRATOR)
}

/// Return the version and checksum of every applied migration, or `None` when
/// the database does not have a migration history yet.
async fn applied_migration_checksums(
    pool: &SqlitePool,
) -> anyhow::Result<Option<Vec<(i64, Vec<u8>)>>> {
    let migrations_table_exists = sqlx::query_scalar::<_, i64>(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'",
    )
    .fetch_optional(pool)
    .await?
    .is_some();
    if !migrations_table_exists {
        return Ok(None);
    }

    let rows = sqlx::query("SELECT version, checksum FROM _sqlx_migrations ORDER BY version")
        .fetch_all(pool)
        .await?;
    let applied = rows
        .into_iter()
        .map(|row| {
            (
                row.get::<i64, _>("version"),
                row.get::<Vec<u8>, _>("checksum"),
            )
        })
        .collect();
    Ok(Some(applied))
}

/// How the applied migration checksums of a database relate to the checksums
/// this build embeds.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MigrationChecksumStatus {
    /// Every applied migration matches the checksum this build embeds.
    Consistent,
    /// The database was migrated by a build whose migration files used
    /// different line endings. The difference is repaired when the database is
    /// opened.
    LineEndingDrift { versions: Vec<i64> },
    /// A migration changed beyond its line endings, so this build refuses to
    /// open the database.
    Modified { version: i64 },
}

/// Compare the applied migration checksums of `pool` with the checksums that
/// `migrator` embeds.
pub async fn inspect_migration_checksums(
    pool: &SqlitePool,
    migrator: &Migrator,
) -> MigrationChecksumStatus {
    let Ok(Some(applied)) = applied_migration_checksums(pool).await else {
        return MigrationChecksumStatus::Consistent;
    };

    let mut drift = Vec::new();
    for (version, checksum) in applied {
        let Some(migration) = migrator
            .iter()
            .find(|migration| migration.version == version)
        else {
            continue;
        };
        if checksum.as_slice() == migration.checksum.as_ref() {
            continue;
        }
        if line_ending_equivalent_checksums(migration.sql.as_str()).contains(&checksum) {
            drift.push(version);
            continue;
        }
        return MigrationChecksumStatus::Modified { version };
    }

    if drift.is_empty() {
        MigrationChecksumStatus::Consistent
    } else {
        MigrationChecksumStatus::LineEndingDrift { versions: drift }
    }
}

/// Return the canonical migrator of a runtime database.
pub(crate) fn canonical_migrator_for(kind: DbKind) -> Migrator {
    match kind {
        DbKind::State => runtime_state_migrator(),
        DbKind::Logs => runtime_logs_migrator(),
        DbKind::Goals => runtime_goals_migrator(),
        DbKind::Memories => runtime_memories_migrator(),
        DbKind::Queue => runtime_queue_migrator(),
        DbKind::ThreadHistory => runtime_thread_history_migrator(),
    }
}

/// Rewrite applied migration checksums that differ from the embedded ones only
/// because of line endings.
///
/// A database migrated by a build that checked the migration files out with CRLF
/// line endings records the CRLF checksum. sqlx compares that against the
/// checksum the current build embeds and reports the migration as modified, so
/// accept the difference and record the checksum this build uses.
pub(crate) async fn repair_line_ending_migration_checksums(
    pool: &SqlitePool,
    migrator: &Migrator,
) -> anyhow::Result<()> {
    let Some(applied) = applied_migration_checksums(pool).await? else {
        return Ok(());
    };

    for (version, checksum) in applied {
        let Some(migration) = migrator
            .iter()
            .find(|migration| migration.version == version)
        else {
            continue;
        };
        if checksum.as_slice() == migration.checksum.as_ref() {
            continue;
        }
        if !line_ending_equivalent_checksums(migration.sql.as_str()).contains(&checksum) {
            continue;
        }
        sqlx::query("UPDATE _sqlx_migrations SET checksum = ? WHERE version = ? AND checksum = ?")
            .bind(migration.checksum.as_ref())
            .bind(version)
            .bind(checksum)
            .execute(pool)
            .await?;
    }
    Ok(())
}

/// Repair a database that holds the recency migration under version 38.
///
/// The recency migration was released as version 38 before it was renamed to
/// version 39, so a database can hold its checksum under version 38. Accept
/// the checksum of any line ending variant because the migration file was
/// checked out with different line endings by different builds.
pub(crate) async fn repair_legacy_recency_migration_version(
    pool: &SqlitePool,
    migrator: &Migrator,
) -> anyhow::Result<()> {
    let Some(recency_migration) = migrator
        .migrations
        .iter()
        .find(|migration| migration.version == 39)
    else {
        return Ok(());
    };
    let Some(applied) = applied_migration_checksums(pool).await? else {
        return Ok(());
    };
    if applied.iter().any(|(version, _)| *version == 39) {
        return Ok(());
    }

    // The recency migration was released as version 38 before it was renamed,
    // so a database can hold its checksum under version 38.
    let equivalent = line_ending_equivalent_checksums(recency_migration.sql.as_str());
    let Some((_, legacy_checksum)) = applied
        .iter()
        .find(|(version, checksum)| *version == 38 && equivalent.contains(checksum))
    else {
        return Ok(());
    };

    sqlx::query(
        r#"
UPDATE _sqlx_migrations
SET version = ?, description = ?, checksum = ?
WHERE version = ?
  AND checksum = ?
  AND NOT EXISTS (
      SELECT 1 FROM _sqlx_migrations WHERE version = ?
  )
        "#,
    )
    .bind(recency_migration.version)
    .bind(recency_migration.description.as_ref())
    .bind(recency_migration.checksum.as_ref())
    .bind(38_i64)
    .bind(legacy_checksum)
    .bind(recency_migration.version)
    .execute(pool)
    .await?;
    Ok(())
}

#[cfg(test)]
#[path = "migrations_tests.rs"]
mod tests;
