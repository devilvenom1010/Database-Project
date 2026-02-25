-- =============================================
-- PROCEDURE 4: Display Info/Warning Message
-- Name: USP_CBS_InfoWarningMessageGet
-- Purpose: Displays informational message without stopping
-- =============================================
CREATE PROCEDURE USP_CBS_Global_Get_InfoWarningMessage
    @MSG_CODE VARCHAR(50),
    @PARAM0 NVARCHAR(500) = NULL,
    @PARAM1 NVARCHAR(500) = NULL,
    @PARAM2 NVARCHAR(500) = NULL,
    @PARAM3 NVARCHAR(500) = NULL,
    @PARAM4 NVARCHAR(500) = NULL,
    @LANG_CODE VARCHAR(10) = 'EN'
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @MESSAGE NVARCHAR(1000);
    DECLARE @ERROR_NUM INT;
    DECLARE @STATE INT;
    DECLARE @SEV INT;
    DECLARE @MSG_TYPE VARCHAR(20);
    
    EXEC USP_CBS_Global_MessageHandler
        @MSG_CODE = @MSG_CODE,
        @PARAM0 = @PARAM0,
        @PARAM1 = @PARAM1,
        @PARAM2 = @PARAM2,
        @PARAM3 = @PARAM3,
        @PARAM4 = @PARAM4,
        @LANG_CODE = @LANG_CODE,
        @MESSAGE = @MESSAGE OUTPUT,
        @ERROR_NUMBER = @ERROR_NUM OUTPUT,
        @STATE = @STATE OUTPUT,
        @SEVERITY = @SEV OUTPUT
    
    -- Display without throwing
    RAISERROR(@MESSAGE, 10, @STATE) WITH NOWAIT;
END;