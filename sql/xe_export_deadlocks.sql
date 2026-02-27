SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;

DECLARE @result XML;

WITH TargetData AS (
    SELECT CAST(event_data AS XML) AS event_data_xml
    FROM sys.fn_xe_file_target_read_file(N'$(xe_path)*.xel', NULL, NULL, NULL)
)
SELECT @result = (
    SELECT 
        event_data_xml.value('(/event/@timestamp)[1]', 'varchar(50)') AS [@timestamp],
        event_data_xml.query('(/event/data[@name="xml_report"]/value/deadlock)[1]') AS [deadlockGraph]
    FROM TargetData
    FOR XML PATH('deadlock'), ROOT('deadlocks'), TYPE
);

IF @result IS NULL
    SET @result = '<deadlocks />';

SELECT @result;
