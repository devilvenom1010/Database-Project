CREATE TYPE TYPE_CBS_Voucher AS TABLE(
	[GL_CODE] [varchar](50) NULL,
	[AC_NO] [varchar](50) NULL,
	[DESC1] [varchar](8000) NULL,
	[AMT] [decimal](18, 2) NULL,
	[BR_CODE] [varchar](50) NULL,
	[INST_CODE] [varchar](50) NULL,
	[INST_NO] [varchar](50) NULL,
	[INST_DATE] [date] NULL,
	[VCH_TYPE] [int] NULL
)
GO


