CREATE TYPE TYPE_CBS_InsuranceHolder AS TABLE(
	[InsuranceOption] [int] NULL,
	[InsuranceCompanyId] [varchar](50) NULL,
	[InsuranceHolderTypeId] [int] NULL,
	[FamilyMemberId] [int] NULL,
	[PolicyNumber] [varchar](50) NULL,
	[PremiumAmount] [decimal](18, 2) NULL,
	[BeneficiaryName] [varchar](50) NULL,
	[BeneficiaryRelation] [varchar](50) NULL,
	[PeriodInMonth] [int] NULL,
	[PolicyExpiryDate] [varchar](50) NULL,
	[DateOfBirth] [date] NULL,
	[GenderCode] [varchar](50) NULL,
	[CitizenshipNumber] [varchar](50) NULL,
	[CitizenshipIssueDate] [date] NULL,
	[CitizenshipIssueDistrictCode] [varchar](50) NULL
)
GO


