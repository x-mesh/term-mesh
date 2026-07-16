use rusqlite::{Connection, OptionalExtension};

use super::registry::RegistryError;

const APPLICATION_ID: i64 = 0x544d_5053; // "TMPS"
const SCHEMA_VERSION: i64 = 1;
const CREATE_SYNC_PROJECTS: &str = "CREATE TABLE sync_projects (
    project_id       BLOB PRIMARY KEY NOT NULL CHECK(length(project_id) = 32),
    root_path        TEXT NOT NULL UNIQUE,
    active_manifest  BLOB CHECK(active_manifest IS NULL OR length(active_manifest) = 32),
    roster_epoch     INTEGER NOT NULL DEFAULT 0 CHECK(roster_epoch >= 0),
    created_at_ms    INTEGER NOT NULL
) STRICT";

pub(super) fn initialize(connection: &Connection) -> Result<(), RegistryError> {
    let initialization = format!(
        "PRAGMA journal_mode=WAL;
         PRAGMA foreign_keys=ON;
         PRAGMA synchronous=FULL;
         BEGIN IMMEDIATE;
         {CREATE_SYNC_PROJECTS};
         PRAGMA application_id = 1414352979;
         PRAGMA user_version = 1;
         COMMIT;"
    );
    connection.execute_batch(&initialization)?;
    Ok(())
}

pub(super) fn configure(connection: &Connection) -> Result<(), RegistryError> {
    connection.execute_batch(
        "PRAGMA journal_mode=WAL;
         PRAGMA foreign_keys=ON;
         PRAGMA synchronous=FULL;",
    )?;
    Ok(())
}

pub(super) fn validate(connection: &Connection) -> Result<(), String> {
    let integrity: String = connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    if integrity != "ok" {
        return Err(format!("quick_check failed: {integrity}"));
    }

    let application_id: i64 = connection
        .query_row("PRAGMA application_id", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    if application_id != APPLICATION_ID {
        return Err(format!(
            "unexpected application_id {application_id}, expected {APPLICATION_ID}"
        ));
    }

    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    if version != SCHEMA_VERSION {
        return Err(format!(
            "unsupported schema version {version}, expected {SCHEMA_VERSION}"
        ));
    }

    let table: Option<(String, i64)> = connection
        .query_row(
            "SELECT type, strict FROM pragma_table_list('sync_projects')
             WHERE schema = 'main' AND name = 'sync_projects'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|error| error.to_string())?;
    match table {
        Some((kind, 1)) if kind == "table" => {}
        Some(_) => return Err("sync_projects must be a STRICT table".to_string()),
        None => return Err("missing sync_projects table".to_string()),
    }

    validate_columns(connection)?;
    validate_root_unique_index(connection)?;
    validate_canonical_ddl(connection)?;
    validate_sqlite_master(connection)?;
    Ok(())
}

fn validate_sqlite_master(connection: &Connection) -> Result<(), String> {
    let mut statement = connection
        .prepare("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name")
        .map_err(|error| error.to_string())?;
    let entries = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })
        .map_err(|error| error.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?;
    if entries.len() != 3 {
        return Err("registry sqlite_master contract drifted".to_string());
    }
    let table = entries.iter().find(|entry| entry.1 == "sync_projects");
    if !matches!(table, Some((kind, _, owner, Some(sql))) if kind == "table" && owner == "sync_projects" && normalize_sql(sql) == normalize_sql(CREATE_SYNC_PROJECTS))
    {
        return Err("registry sqlite_master table drifted".to_string());
    }
    let auto_indexes = entries
        .iter()
        .filter(|entry| entry.0 == "index" && entry.2 == "sync_projects" && entry.3.is_none())
        .count();
    if auto_indexes != 2 {
        return Err("registry sqlite_master index allowlist drifted".to_string());
    }
    Ok(())
}

fn validate_columns(connection: &Connection) -> Result<(), String> {
    let mut statement = connection
        .prepare("PRAGMA table_xinfo('sync_projects')")
        .map_err(|error| error.to_string())?;
    let columns = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, i64>(6)?,
            ))
        })
        .map_err(|error| error.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?;
    let expected = vec![
        ("project_id".to_string(), "BLOB".to_string(), 1, None, 1, 0),
        ("root_path".to_string(), "TEXT".to_string(), 1, None, 0, 0),
        (
            "active_manifest".to_string(),
            "BLOB".to_string(),
            0,
            None,
            0,
            0,
        ),
        (
            "roster_epoch".to_string(),
            "INTEGER".to_string(),
            1,
            Some("0".to_string()),
            0,
            0,
        ),
        (
            "created_at_ms".to_string(),
            "INTEGER".to_string(),
            1,
            None,
            0,
            0,
        ),
    ];
    if columns != expected {
        return Err("sync_projects column contract drifted".to_string());
    }
    Ok(())
}

fn validate_root_unique_index(connection: &Connection) -> Result<(), String> {
    let mut statement = connection
        .prepare("PRAGMA index_list('sync_projects')")
        .map_err(|error| error.to_string())?;
    let indexes = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })
        .map_err(|error| error.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?;

    if indexes.len() != 2 {
        return Err("sync_projects index contract drifted".to_string());
    }
    let mut found_primary_key = false;
    let mut found_root_unique = false;
    for (index_name, unique, origin, partial) in indexes {
        let mut columns = connection
            .prepare("SELECT name FROM pragma_index_info(?1) ORDER BY seqno")
            .map_err(|error| error.to_string())?;
        let names = columns
            .query_map([&index_name], |row| row.get::<_, String>(0))
            .map_err(|error| error.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| error.to_string())?;
        match (unique, partial, origin.as_str(), names.as_slice()) {
            (1, 0, "pk", [name]) if name == "project_id" => found_primary_key = true,
            (1, 0, "u", [name]) if name == "root_path" => found_root_unique = true,
            _ => return Err("sync_projects index contract drifted".to_string()),
        }
    }
    if !found_primary_key || !found_root_unique {
        return Err("sync_projects index contract drifted".to_string());
    }
    Ok(())
}

fn validate_canonical_ddl(connection: &Connection) -> Result<(), String> {
    let sql: String = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'sync_projects'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    if normalize_sql(&sql) != normalize_sql(CREATE_SYNC_PROJECTS) {
        return Err("sync_projects canonical v1 DDL drifted".to_string());
    }
    Ok(())
}

fn normalize_sql(sql: &str) -> String {
    let mut normalized = String::with_capacity(sql.len());
    let mut pending_space = false;
    for character in sql.trim().chars() {
        if character.is_ascii_whitespace() {
            pending_space = true;
        } else {
            if pending_space && !normalized.is_empty() {
                normalized.push(' ');
            }
            pending_space = false;
            normalized.push(character);
        }
    }
    normalized
}
