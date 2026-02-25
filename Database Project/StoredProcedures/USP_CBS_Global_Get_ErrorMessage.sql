-- =============================================
-- PROCEDURE 2: Return Error Message
-- Name: USP_CBS_ErrorMessageGet
-- Purpose: Raises error and stops execution
-- =============================================
CREATE PROCEDURE USP_CBS_Global_Get_ErrorMessage
    @MSG_CODE VARCHAR(50),
    @PARAM0 NVARCHAR(500) = NULL,
    @PARAM1 NVARCHAR(500) = NULL,
    @PARAM2 NVARCHAR(500) = NULL,
    @PARAM3 NVARCHAR(500) = NULL,
    @PARAM4 NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @MESSAGE NVARCHAR(1000);
    DECLARE @ERROR_NUM INT;
    DECLARE @STATE INT;
    DECLARE @SEV INT;
    
    -- This will automatically throw the error
    EXEC USP_CBS_Global_MessageHandler 
        @MSG_CODE = @MSG_CODE,
        @PARAM0 = @PARAM0,
        @PARAM1 = @PARAM1,
        @PARAM2 = @PARAM2,
        @PARAM3 = @PARAM3,
        @PARAM4 = @PARAM4,
        @MESSAGE = @MESSAGE OUTPUT,
        @ERROR_NUMBER = @ERROR_NUM OUTPUT,
        @STATE = @STATE OUTPUT,
        @SEVERITY = @SEV OUTPUT;
END;