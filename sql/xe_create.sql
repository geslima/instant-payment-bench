SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'InstantPaymentBenchXe')
BEGIN
    DROP EVENT SESSION [InstantPaymentBenchXe] ON SERVER;
END

CREATE EVENT SESSION [InstantPaymentBenchXe] ON SERVER 
ADD EVENT sqlserver.xml_deadlock_report
ADD TARGET package0.event_file(SET filename=N'$(xe_path).xel', max_file_size=(50), max_rollover_files=(10))
WITH (MAX_MEMORY=4096 KB, EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY=30 SECONDS, MAX_EVENT_SIZE=0 KB, MEMORY_PARTITION_MODE=NONE, TRACK_CAUSALITY=OFF, STARTUP_STATE=OFF);
