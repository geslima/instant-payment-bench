SET NOCOUNT ON;

PRINT '=== 1. Server Identity ===';
SELECT 
    @@VERSION AS VersionString,
    SERVERPROPERTY('ProductVersion') AS ProductVersion,
    SERVERPROPERTY('ProductLevel') AS ProductLevel,
    SERVERPROPERTY('Edition') AS Edition;

PRINT '=== 2. sys.configurations ===';
SELECT name, value, value_in_use 
FROM sys.configurations 
WHERE name IN (
    'max server memory (MB)', 
    'min server memory (MB)', 
    'cost threshold for parallelism', 
    'max degree of parallelism', 
    'optimize for ad hoc workloads',
    'query optimizer hotfixes', 
    'legacy cardinality estimation'
);

PRINT '=== 3. Database Options ===';
SELECT 
    name,
    recovery_model_desc, 
    is_read_committed_snapshot_on,
    snapshot_isolation_state_desc, 
    is_auto_update_stats_on,
    is_auto_update_stats_async_on, 
    page_verify_option_desc,
    delayed_durability_desc
FROM sys.databases 
WHERE name = DB_NAME();

PRINT '=== 4. TempDB Layout ===';
SELECT 
    file_id, type_desc, name, physical_name, 
    size * 8 / 1024 AS size_mb, 
    max_size, growth, is_percent_growth
FROM sys.master_files 
WHERE database_id = 2;

PRINT '=== 5. Benchmark Database File Layout ===';
SELECT 
    mf.file_id, mf.type_desc, mf.name, mf.physical_name, 
    mf.size * 8 / 1024 AS size_mb, 
    mf.max_size, mf.growth, mf.is_percent_growth
FROM sys.master_files mf
JOIN sys.databases d ON mf.database_id = d.database_id
WHERE d.name = DB_NAME();

PRINT '=== 6. IO Stall Metrics ===';
SELECT 
    mf.name AS logical_file_name,
    mf.physical_name,
    vfs.num_of_reads,
    vfs.num_of_writes,
    vfs.io_stall_read_ms,
    vfs.io_stall_write_ms,
    CASE WHEN vfs.num_of_reads > 0 THEN vfs.io_stall_read_ms / vfs.num_of_reads ELSE 0 END AS avg_read_stall_ms,
    CASE WHEN vfs.num_of_writes > 0 THEN vfs.io_stall_write_ms / vfs.num_of_writes ELSE 0 END AS avg_write_stall_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id;
