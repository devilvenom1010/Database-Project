-- =============================================
-- Procedure: USP_CBS_MessageHandler
-- Returns formatted validation message via OUTPUT parameter
-- =============================================
CREATE PROCEDURE USP_CBS_Global_MessageHandler
    @MSG_CODE VARCHAR(50),
    @PARAM0 NVARCHAR(500) = NULL,
    @PARAM1 NVARCHAR(500) = NULL,
    @PARAM2 NVARCHAR(500) = NULL,
    @PARAM3 NVARCHAR(500) = NULL,
    @PARAM4 NVARCHAR(500) = NULL,
    @LANG_CODE VARCHAR(10) = 'EN',

    -- Output parameters
    @MESSAGE NVARCHAR(1000) OUTPUT,
    @ERROR_NUMBER INT OUTPUT,
    @STATE INT OUTPUT,
    @SEVERITY INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MSG_TYPE VARCHAR(20);
    
    ---- Try to get language-specific message first
    --SELECT 
    --    @MESSAGE = MSG_TEMPLATE
    --FROM VALIDATION_MESSAGE_LANG
    --WHERE MSG_CODE = @MSG_CODE 
    --    AND LANG_CODE = @LANG_CODE 
    --    AND IS_ACTIVE = 1;

    -- Get message details from master
    SELECT 
        @MESSAGE = MSG_TEMPLATE,
        @MSG_TYPE = MSG_TYPE,
        @ERROR_NUMBER = ERROR_NUMBER,
        @STATE = STATE_CODE,
        @SEVERITY = MSG_SEVERITY
    FROM APP_SYS_MSG_MAIN
    WHERE MSG_CODE = @MSG_CODE AND IS_ACTIVE = 1;
    
    -- Fallback to master table if no language-specific message
    IF @MESSAGE IS NULL
    BEGIN
        SELECT 
            @MESSAGE = MSG_TEMPLATE
        FROM APP_SYS_MSG_MAIN
        WHERE MSG_CODE = @MSG_CODE AND IS_ACTIVE = 1;
    END

    -- Return default message if not found
    IF @MESSAGE IS NULL
    BEGIN
        SET @MESSAGE = 'An unexpected error occurred. Message code: ' + ISNULL(@MSG_CODE, 'UNKNOWN');
        SET @ERROR_NUMBER = 50001;
        SET @STATE = 1;
        SET @SEVERITY = 4; -- Critical
        
        -- For unknown messages, throw error immediately
        ;THROW @ERROR_NUMBER, @MESSAGE, @STATE;
    END
    
    -- Replace placeholders with parameters
    SET @MESSAGE = REPLACE(@MESSAGE, '{0}', ISNULL(@PARAM0, ''));
    SET @MESSAGE = REPLACE(@MESSAGE, '{1}', ISNULL(@PARAM1, ''));
    SET @MESSAGE = REPLACE(@MESSAGE, '{2}', ISNULL(@PARAM2, ''));
    SET @MESSAGE = REPLACE(@MESSAGE, '{3}', ISNULL(@PARAM3, ''));
    SET @MESSAGE = REPLACE(@MESSAGE, '{4}', ISNULL(@PARAM4, ''));

    -- Handle based on message type
    IF @MSG_TYPE = 'ERROR'
    BEGIN
        -- Throw error (stops execution)
        ;THROW @ERROR_NUMBER, @MESSAGE, @STATE;
    END
    ELSE IF @MSG_TYPE = 'WARNING'
    BEGIN
        -- For warnings, use RAISERROR with NOWAIT to display but continue
        -- OR throw if you want to stop execution
        RAISERROR(@MESSAGE, 10, @STATE) WITH NOWAIT;
        -- Alternatively: ;THROW @ERROR_NUMBER, @MESSAGE, @STATE;
    END
    ELSE IF @MSG_TYPE = 'INFO'
    BEGIN
        -- For INFO, print message without stopping execution
        RAISERROR(@MESSAGE, 10, @STATE) WITH NOWAIT;
    END
    
    -- For SUCCESS type, just set the OUTPUT parameters
    --SELECT @MESSAGE
END;