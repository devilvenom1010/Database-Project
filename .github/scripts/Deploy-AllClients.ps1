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

    # --- Phase 1: Pre-flight — generate script, then trial-run inside a rolled-back transaction ---
    try {
        $tempScript = [System.IO.Path]::GetTempFileName() + ".sql"

        # Step 1a: Generate the deployment T-SQL without executing it
        $scriptOutput = & sqlpackage `
            /Action:Script `
            /SourceFile:"$dacpac" `
            /TargetServerName:"$($client.ServerName)" `
            /TargetDatabaseName:"$($client.DatabaseName)" `
            /TargetUser:"$user" `
            /TargetPassword:"$pass" `
            /TargetTrustServerCertificate:True `
            /OutputPath:"$tempScript" `
            /p:BlockOnPossibleDataLoss=false `
            /p:DropObjectsNotInSource=false `
            /p:TreatVerificationErrorsAsWarnings=true `
            2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorLines = $scriptOutput | Where-Object {
                $_ -match "Error SQL|Invalid column|Invalid object|Cannot find|Could not|Msg \d+"
            }
            $errText = if ($errorLines) { $errorLines -join " | " } else { $scriptOutput -join " | " }
            throw "[Script generation failed] $errText"
        }

        # Step 1b: Dry-run inside a rolled-back ADO.NET transaction.
        # Every GO-batch is executed for real inside one transaction, then always rolled back.
        # Unlike SET NOEXEC ON, real execution means CREATE TYPE/TABLE in early batches are
        # visible to later batches — so procedures referencing newly-deployed UDTs compile fine.
        $generatedSql = Get-Content -Path $tempScript -Raw
        if (Test-Path $tempScript) { Remove-Item $tempScript -Force }

        # --- Resolve sqlcmd variables before stripping directives ---
        # sqlpackage generates :setvar lines to define variables (e.g. :setvar DatabaseName "INFINITY_094_001")
        # and references them as $(DatabaseName) throughout. SqlCommand doesn't resolve these,
        # so we parse :setvar definitions first, substitute all $(VarName) occurrences, then
        # strip the remaining sqlcmd directive lines.
        $sqlcmdVars = @{}
        # Seed known values so they resolve even if not declared via :setvar
        $sqlcmdVars['DatabaseName'] = $client.DatabaseName
        $sqlcmdVars['ServerName'] = $client.ServerName

        foreach ($ln in ($generatedSql -split '\r?\n')) {
            if ($ln -match '^\s*:setvar\s+(\w+)\s+"?([^"]*)"?\s*$') {
                $sqlcmdVars[$Matches[1]] = $Matches[2]
            }
        }
        foreach ($key in $sqlcmdVars.Keys) {
            # Build the literal placeholder $(VarName) and regex-escape it for -replace.
            # NOTE: do NOT use "`$($key)" — that produces "$VarName" (no parens), which
            # won't match the $(VarName) syntax sqlpackage writes into the script.
            $placeholder = [regex]::Escape('$(' + $key + ')')
            $generatedSql = $generatedSql -replace $placeholder, $sqlcmdVars[$key]
        }

        # Strip all remaining sqlcmd directives (lines starting with ':') — not valid T-SQL
        $generatedSql = ($generatedSql -split '\r?\n' |
            Where-Object { $_ -notmatch '^\s*:' }) -join "`n"

        # Split on GO (case-insensitive, on its own line, optional whitespace)
        $batches = $generatedSql -split '(?im)^\s*GO\s*$' |
        Where-Object { $_.Trim() -ne '' }

        $trialConn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=$($client.ServerName);Database=$($client.DatabaseName);User Id=$user;Password=$pass;TrustServerCertificate=True;Encrypt=False;"
        )
        $trialConn.Open()
        $trialTxn = $trialConn.BeginTransaction()
        try {
            # SET XACT_ABORT ON so any batch error immediately aborts the transaction.
            $xactCmd = $trialConn.CreateCommand()
            $xactCmd.Transaction = $trialTxn
            $xactCmd.CommandText = "SET XACT_ABORT ON;"
            $xactCmd.ExecuteNonQuery() | Out-Null

            foreach ($batch in $batches) {
                if ([string]::IsNullOrWhiteSpace($batch)) { continue }

                # Extract the object name from this batch so we can report it on failure.
                # Matches: CREATE/ALTER PROCEDURE|TABLE|TYPE|VIEW|FUNCTION [schema.]name
                $objectName = '(unknown object)'
                if ($batch -match '(?i)(?:CREATE|ALTER)\s+(?:PROCEDURE|PROC|TABLE|TYPE|VIEW|FUNCTION)\s+(?:\[?\w+\]?\.)?\[?(\w+)\]?') {
                    $objectName = $Matches[1]
                }

                try {
                    $batchCmd = $trialConn.CreateCommand()
                    $batchCmd.Transaction = $trialTxn
                    $batchCmd.CommandText = $batch
                    $batchCmd.CommandTimeout = 120
                    $batchCmd.ExecuteNonQuery() | Out-Null
                }
                catch {
                    # Re-throw with the object name embedded using the same 'Procedure X' token
                    # that the summary parser already recognises, so SCRIPT: lines appear in output.
                    throw "Procedure $objectName | $($_.Exception.Message)"
                }
            }
        }
        catch {
            throw "[Dry-run failed — no changes were applied] $($_.Exception.Message)"
        }
        finally {
            # Always roll back — the transaction exists only to validate, never to persist.
            try { $trialTxn.Rollback() } catch {}
            $trialConn.Close()
        }

        $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] PRE-FLIGHT OK: $($client.ClientName) ($($client.DatabaseName)) — proceeding with deployment"
        Write-Host $line
        Add-Content -Path $logFile -Value $line
    }
    catch {
        $status = "Failed"
        $message = $_.Exception.Message
        $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] PRE-FLIGHT FAILED (skipped deploy): $($client.ClientName) ($($client.DatabaseName)) — $message"
        Write-Host $line
        Add-Content -Path $logFile -Value $line
        if (Test-Path $tempScript) { Remove-Item $tempScript -Force }
    }

    # --- Phase 2: Actual deployment (only if pre-flight passed) ---
    if ($status -eq "Success") {
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
                /p:IncludeTransactionalScripts=True `
                2>&1

            if ($LASTEXITCODE -ne 0) {
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
            if ($part -match "Invalid column name '([^']+)'") {
                Write-Log "  ERROR:    Invalid column: $($Matches[1])"
            }
            if ($part -match "Invalid object name '([^']+)'") {
                Write-Log "  ERROR:    Invalid object: $($Matches[1])"
            }
            if ($part -match "Cannot find data type ([^.\r\n]+)") {
                Write-Log "  ERROR:    Missing type: $($Matches[1].Trim())"
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