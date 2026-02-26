-- 1. Create the new History table
CREATE TABLE dbo.ClientDeploymentHistory
(
    HistoryId INT IDENTITY(1,1) PRIMARY KEY,
    ClientId INT NOT NULL,
    DeployedBy VARCHAR(100) NOT NULL,
    DeployedAt DATETIME NOT NULL DEFAULT GETDATE(),
    DeployStatus VARCHAR(50) NOT NULL,
    VersionNumber VARCHAR(50) NULL,
    ErrorMessage NVARCHAR(MAX) NULL,
    ActiveVersion VARCHAR(50) NULL

);
