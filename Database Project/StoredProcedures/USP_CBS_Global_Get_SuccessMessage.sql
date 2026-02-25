-- =============================================
-- PROCEDURE 3: Return Success Message
-- Name: USP_CBS_SuccessMessageGet
-- Purpose: Returns success message without throwing
-- =============================================
CREATE PROCEDURE USP_CBS_Global_Get_SuccessMessage
    @MSG_CODE VARCHAR(50),
    @PARAM0 NVARCHAR(500) = NULL,
    @PARAM1 NVARCHAR(500) = NULL,
    @PARAM2 NVARCHAR(500) = NULL,
    @PARAM3 NVARCHAR(500) = NULL,
    @PARAM4 NVARCHAR(500) = NULL,
    @LANG_CODE VARCHAR(10) = 'EN',
    @SUCCESS_MESSAGE NVARCHAR(1000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @ERROR_NUM INT;
    DECLARE @STATE INT;
    DECLARE @SEV INT;
    
    EXEC USP_CBS_Global_MessageHandler
        @MSG_CODE = @MSG_CODE,
        @PARAM0 = @PARAM0,
        @PARAM1 = @PARAM1,
        @PARAM2 = @PARAM2,
        @PARAM3 = @PARAM3,
        @PARAM4 = @PARAM4,
        @LANG_CODE = @LANG_CODE,
        @MESSAGE = @SUCCESS_MESSAGE OUTPUT,
        @ERROR_NUMBER = @ERROR_NUM OUTPUT,
        @STATE = @STATE OUTPUT,
        @SEVERITY = @SEV OUTPUT
        --@MSG_TYPE = @MSG_TYPE OUTPUT;
END;