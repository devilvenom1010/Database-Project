CREATE TABLE dbo.SchemaVersion
(
    VersionNumber VARCHAR(50) NOT NULL,
    DeployedOn DATETIME NOT NULL,
    DeployedBy VARCHAR(100) NOT NULL,
    CONSTRAINT PK_SchemaVersion_VersionNumber PRIMARY KEY (VersionNumber)
);