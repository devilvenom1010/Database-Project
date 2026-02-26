param(
    [string]$DacpacPath,
    [string]$RegistryServer,
    [string]$RegistryDatabase,
    [string]$SqlUser,
    [string]$SqlPassword,
    [string]$VersionNumber
)

# --- Log file setup ---
$logDir = "D:\Database Deployment\Database Project\DeploymentLogs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "deployment-$((Get-Date).ToString('yyyy-MM-dd-HHmmss')).log"

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

# --- Initialize Registry Schema if missing ---
$connStr = "Server=$RegistryServer;Database=$RegistryDatabase;User Id=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;Encrypt=False;"
try {
    $initConn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $initConn.Open()
    $initCmd = $initConn.CreateCommand()
    $initCmd.CommandText = @"
IF OBJECT_ID('dbo.ClientDeploymentHistory', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ClientDeploymentHistory
    (
        HistoryId INT IDENTITY(1,1) PRIMARY KEY,
        ClientId INT NOT NULL,
        DeployedBy VARCHAR(100) NOT NULL,
        DeployedAt DATETIME NOT NULL DEFAULT GETDATE(),
        DeployStatus VARCHAR(50) NOT NULL,
        VersionNumber VARCHAR(50) NULL,
        ErrorMessage NVARCHAR(MAX) NULL
    );
END

IF COL_LENGTH('dbo.ClientDeploymentRegistry', 'ActiveVersion') IS NULL
BEGIN
    ALTER TABLE dbo.ClientDeploymentRegistry ADD ActiveVersion VARCHAR(50) NULL;
END
"@
    $initCmd.ExecuteNonQuery() | Out-Null
    $initConn.Close()
    Write-Log "Registry database schema verified."
}
catch {
    Write-Log "WARNING: Could not verify/initialize Registry database schema. Error: $($_.Exception.Message)"
}


# --- Load client list from central registry ---
$query = "SELECT ClientId, ClientName, ServerName, DatabaseName FROM dbo.ClientDeploymentRegistry WHERE IsActive = 1"

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $query
    $reader = $cmd.ExecuteReader()

    $clients = @()
    while ($reader.Read()) {
        $clients += [PSCustomObject]@{
            ClientId     = $reader["ClientId"]
            ClientName   = $reader["ClientName"]
            ServerName   = $reader["ServerName"]
            DatabaseName = $reader["DatabaseName"]
        }
    }
    $reader.Close()
    $conn.Close()
}
catch {
    Write-Log "FATAL: Could not connect to registry database. Error: $($_.Exception.Message)"
    exit 1
}

Write-Log "Found $($clients.Count) active clients. Starting parallel deployment..."

# --- Deploy to all clients in parallel ---
$results = $clients | ForEach-Object -Parallel {
    $client = $_
    $dacpac = $using:DacpacPath
    $user = $using:SqlUser
    $pass = $using:SqlPassword
    $regServer = $using:RegistryServer
    $regDb = $using:RegistryDatabase
    $logFile = $using:logFile
    $versionNu = $using:VersionNumber

    $status = "Success"
    $message = ""

    try {
        $output = & sqlpackage `
            /Action:Publish `
            /SourceFile:"$dacpac" `
            /TargetServerName:"$($client.ServerName)" `
            /TargetDatabaseName:"$($client.DatabaseName)" `
            /TargetUser:"$user" `
            /TargetPassword:"$pass" `
            /TargetTrustServerCertificate:True `
            /p:BlockOnPossibleDataLoss=false `
            /p:DropObjectsNotInSource=false `
            /p:TreatVerificationErrorsAsWarnings=true `
            2>&1

        if ($LASTEXITCODE -ne 0) {
            # Extract only meaningful error lines, skip informational output
            $errorLines = $output | Where-Object {
                $_ -match "Error SQL|Invalid column|Invalid object|Cannot find|Could not|Msg \d+"
            }
            throw ($errorLines -join " | ")
        }

        $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] SUCCESS: $($client.ClientName) ($($client.DatabaseName))"
        Write-Host $line
        Add-Content -Path $logFile -Value $line
    }
    catch {
        $status = "Failed"
        $message = $_.Exception.Message
    }

    # --- Update client SchemaVersion table ---
    if ($status -eq "Success" -and -not [string]::IsNullOrEmpty($versionNu)) {
        try {
            $clientConn = New-Object System.Data.SqlClient.SqlConnection("Server=$($client.ServerName);Database=$($client.DatabaseName);User Id=$user;Password=$pass;TrustServerCertificate=True;Encrypt=False;")
            $clientConn.Open()
            $clientCmd = $clientConn.CreateCommand()
            $clientCmd.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = @v)
BEGIN
    INSERT INTO dbo.SchemaVersion (VersionNumber, DeployedOn, DeployedBy)
    VALUES (@v, GETDATE(), 'GitHub Actions')
END
ELSE
BEGIN
    UPDATE dbo.SchemaVersion SET DeployedOn = GETDATE(), DeployedBy = 'GitHub Actions' WHERE VersionNumber = @v
END
"@
            $clientCmd.Parameters.AddWithValue("@v", $versionNu) | Out-Null
            $clientCmd.ExecuteNonQuery() | Out-Null
            $clientConn.Close()
        }
        catch {
            $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WARNING: Could not update SchemaVersion on client database for $($client.ClientName) - $($_.Exception.Message)"
            Write-Host $line
            Add-Content -Path $logFile -Value $line
        }
    }

    # --- Update registry with result ---
    try {
        $updateConn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=$regServer;Database=$regDb;User Id=$user;Password=$pass;TrustServerCertificate=True;Encrypt=False;"
        )
        $updateConn.Open()
        
        # 1. Insert into history table
        $historyCmd = $updateConn.CreateCommand()
        $historyCmd.CommandText = @"
INSERT INTO dbo.ClientDeploymentHistory (ClientId, DeployedBy, DeployedAt, DeployStatus, VersionNumber, ErrorMessage)
VALUES (@id, @user, GETDATE(), @s, @version, @error)
"@
        $historyCmd.Parameters.AddWithValue("@id", $client.ClientId) | Out-Null
        $historyCmd.Parameters.AddWithValue("@user", "GitHub Actions") | Out-Null
        $historyCmd.Parameters.AddWithValue("@s", $status) | Out-Null
        $historyCmd.Parameters.AddWithValue("@version", [string]::IsNullOrEmpty($versionNu) ? [System.DBNull]::Value : $versionNu) | Out-Null
        $historyCmd.Parameters.AddWithValue("@error", [string]::IsNullOrEmpty($message) ? [System.DBNull]::Value : $message) | Out-Null
        $historyCmd.ExecuteNonQuery() | Out-Null
        
        # 2. Update registry
        $updateCmd = $updateConn.CreateCommand()
        if ($status -eq "Success" -and -not [string]::IsNullOrEmpty($versionNu)) {
            $updateCmd.CommandText = "UPDATE dbo.ClientDeploymentRegistry SET LastDeployedAt = GETDATE(), LastDeployStatus = @s, ActiveVersion = @v WHERE ClientId = @id"
            $updateCmd.Parameters.AddWithValue("@v", $versionNu) | Out-Null
        }
        else {
            $updateCmd.CommandText = "UPDATE dbo.ClientDeploymentRegistry SET LastDeployedAt = GETDATE(), LastDeployStatus = @s WHERE ClientId = @id"
        }
        $updateCmd.Parameters.AddWithValue("@s", $status)          | Out-Null
        $updateCmd.Parameters.AddWithValue("@id", $client.ClientId) | Out-Null
        $updateCmd.ExecuteNonQuery() | Out-Null
        
        $updateConn.Close()
    }
    catch {
        $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WARNING: Could not update registry for $($client.ClientName) - $($_.Exception.Message)"
        Write-Host $line
        Add-Content -Path $logFile -Value $line
    }

    return [PSCustomObject]@{
        Client   = $client.ClientName
        Database = $client.DatabaseName
        Status   = $status
        Error    = $message
    }

} -ThrottleLimit 50

# --- Summary first ---
$failed = $results | Where-Object { $_.Status -eq "Failed" }
$success = $results | Where-Object { $_.Status -eq "Success" }

Write-Log ""
Write-Log "===== DEPLOYMENT SUMMARY ====="
Write-Log "Succeeded: $($success.Count)"
Write-Log "Failed:    $($failed.Count)"
if ($success.Count -gt 0) {
    Write-Log ""
    Write-Log "--- Successful Clients ---"
    $success | ForEach-Object { Write-Log "  + $($_.Client) ($($_.Database))" }
}

# --- Failed details after summary ---
if ($failed.Count -gt 0) {
    Write-Log ""
    Write-Log "--- Failed Clients ---"
    $failed | ForEach-Object {
        Write-Log "  CLIENT:   $($_.Client) ($($_.Database))"
        # Extract just procedure names and column errors
        $_.Error -split "\|" | ForEach-Object {
            $part = $_.Trim()
            if ($part -match "Procedure (\S+)") {
                Write-Log "  SCRIPT:   $($Matches[1])"
            }
            if ($part -match "Invalid column name '(\S+)'") {
                Write-Log "  ERROR:    Invalid column: $($Matches[1])"
            }
            if ($part -match "Invalid object name '(\S+)'") {
                Write-Log "  ERROR:    Invalid object: $($Matches[1])"
            }
        }
        Write-Log "  ---"
    }
    exit 1
}
else {
    Write-Log ""
    Write-Log "All deployments succeeded!"
    exit 0
}