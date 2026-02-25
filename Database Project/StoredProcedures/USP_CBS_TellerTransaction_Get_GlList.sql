CREATE  PROCEDURE USP_CBS_TellerTransaction_Get_GlList
(
    @INPUT VARCHAR(100),
    @SESSION_BR_CODE VARCHAR(10)
)
AS
BEGIN

    SELECT TOP 20 AC.GL_CODE, AC.GL_NAME ,AC.SUBLEDGER
                                        FROM AC_CHART AC
                                        LEFT OUTER JOIN AC_GROUP_GL_MAP AGGM ON AC.GL_CODE = AGGM.GL_CODE
                                        LEFT OUTER JOIN BANK_ACNO BN ON BN.NOSTRO_GL_CODE = AC.GL_CODE
                                        LEFT OUTER JOIN CURRENCY C ON (AC.GL_CODE=C.VAULT_GL_CODE OR AC.GL_CODE=C.HEAD_TELLER_GL_CODE OR AC.GL_CODE=C.TELLER_GL_CODE)
                                        LEFT OUTER JOIN (SELECT AG_GL_CODE ,BR_CODE, EXCL_USE
                                                            FROM AC_GROUP_BR_EXCL_USE
                                                            WHERE BR_CODE <> @SESSION_BR_CODE AND EXCL_USE='YES'
                                                        ) AG ON AG.AG_GL_CODE=AC.GL_CODE
                                        WHERE AC.APPROVED='YES' AND AC.LEDGER='YES' AND AC.TRAN_ALLOWED='YES' AND AC.ALLOW_FREE_ENTRY='YES' AND AC.IN_TRANSIT<>'YES'
                                        AND AC.IBT_AC<>'YES' AND (C.VAULT_GL_CODE IS NULL OR C.HEAD_TELLER_GL_CODE IS NULL OR C.TELLER_GL_CODE IS NULL) 
                                        AND AGGM.GL_CODE IS NULL AND AG.AG_GL_CODE IS NULL
                                        AND (BN.AC_CLOSE = 'NO' OR BN.BANK_CODE IS NULL)
                                        AND AC.PROJECT_CODE='' AND (AC.BANK_GL_CODE = @INPUT OR AC.GL_NAME LIKE @INPUT+'%')

END
--GO
--EXEC USP_TellerTransaction_Get_GlList
--@INPUT='',
--@SESSION_BR_CODE='001'

