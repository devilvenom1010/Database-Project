-- =============================================
-- 1. APP_SYS_MSG_MAIN
-- Stores all validation messages with codes
-- =============================================
CREATE TABLE APP_SYS_MSG_MAIN (
    MSG_ID INT IDENTITY(1,1),
    MSG_CODE VARCHAR(50),
    MSG_TYPE VARCHAR(20) NOT NULL, -- 'ERROR', 'WARNING', 'INFO', 'SUCCESS'
    MSG_CATEGORY VARCHAR(50) NOT NULL,
    MSG_TEMPLATE VARCHAR(1000) NOT NULL,
    
    -- RAISERROR severity: 11-16 for errors, 10 for info
    -- 18: CRITICAL (though typically reserved for system-level issues, using 18 for critical application errors)
    -- 16: ERROR
    -- 14: WARNING 
    -- 10: INFO
    -- 10: SUCCESS (though technically could be 0 or 10, using 10 for consistency with info)
     MSG_SEVERITY AS (
        CASE 
            -- If it's a Security error, make it more severe
            --WHEN MSG_TYPE = 'ERROR' AND MSG_CATEGORY = 'Security' THEN 18
            WHEN MSG_TYPE = 'ERROR' THEN 16
            --WHEN MSG_TYPE = 'WARNING' AND MSG_CATEGORY = 'Security' THEN 16  -- Security warnings are more important
            WHEN MSG_TYPE = 'WARNING' THEN 14
            WHEN MSG_TYPE = 'INFO' THEN 10
            WHEN MSG_TYPE = 'SUCCESS' THEN 10
            ELSE 16 
        END
    ) PERSISTED,
    
    -- RAISERROR state: typically 1-127
    -- Most user-defined errors use state 1 (the default)
    -- State values 1-127: Available for user-defined purposes
    -- State values 128-255: Reserved (though technically usable)
    STATE_CODE INT CONSTRAINT DF_AppSysMsgMain_StateCode DEFAULT 1, 
    
    -- For RAISERROR: 50000-2147483647
    -- 50001: Validation errors
    -- 50101: Business rule errors
    -- 50201: Data integrity errors
    -- 50301: Security errors
    -- 50401: Warning messages
    [ERROR_NUMBER] AS (
        CASE MSG_CATEGORY
            WHEN 'Validation' THEN 50001
            WHEN 'Business rule' THEN 50101
            WHEN 'Data integrity' THEN 50201
            WHEN 'Security' THEN 50301
            WHEN 'Warning' THEN 50401
            ELSE 50001
        END
    ) PERSISTED,  
    
    IS_ACTIVE BIT CONSTRAINT DF_AppSysMsgMain_IsActive DEFAULT 1,
    CREATED_USER_ID VARCHAR(50),
    CREATED_DATE DATETIME CONSTRAINT DF_AppSysMsgMain_CreatedDate DEFAULT GETDATE(),
    MODIFIED_USER_ID VARCHAR(50),
    MODIFIED_DATE DATETIME,
    REMARKS VARCHAR(500),
    
    -- Primary Key
    CONSTRAINT PK_AppSysMsgMain_MsgId PRIMARY KEY (MSG_ID),
    
    -- Check Constraints
    CONSTRAINT CHK_AppSysMsgMain_MsgType CHECK (MSG_TYPE IN ('ERROR', 'WARNING', 'INFO', 'SUCCESS')),
    CONSTRAINT CHK_AppSysMsgMain_MsgCategory CHECK (MSG_CATEGORY IN ('Validation', 'Business rule', 'Data integrity', 'Security', 'Warning')),
    CONSTRAINT CHK_AppSysMsgMain_StateCode CHECK (STATE_CODE BETWEEN 1 AND 127),
    
    -- Unique Constraints
    CONSTRAINT UQ_AppSysMsgMain_MsgCode UNIQUE (MSG_CODE)
);
GO

CREATE NONCLUSTERED INDEX IX_AppSysMsgMain_MsgCodeIsActive 
ON APP_SYS_MSG_MAIN(MSG_CODE, IS_ACTIVE) 
INCLUDE (MSG_TEMPLATE, MSG_TYPE, MSG_CATEGORY, MSG_SEVERITY, STATE_CODE, [ERROR_NUMBER]);