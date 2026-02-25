param(
    [string]$DacpacPath,
    [string]$RegistryServer,
    [string]$RegistryDatabase,
    [string]$SqlUser,
    [string]$SqlPassword
)

# --- Log file setup ---
$repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$logDir   = Join-Path $repoRoot "DeploymentLogs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile  = Join-Path $logDir "deployment-$((Get-Date).ToString('yyyy-MM-dd-HHmmss')).log"

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

# --- Load client list from central registry ---
$connStr = "Server=$RegistryServer;Database=$RegistryDatabase;User Id=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;Encrypt=False;"
$query   = "SELECT ClientId, ClientName, ServerName, DatabaseName FROM dbo.ClientDeploymentRegistry WHERE IsActive = 1"

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    $cmd  = $conn.CreateCommand()
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
    $client    = $_
    $dacpac    = $using:DacpacPath
    $user      = $using:SqlUser
    $pass      = $using:SqlPassword
    $regServer = $using:RegistryServer
    $regDb     = $using:RegistryDatabase
    $logFile   = $using:logFile

    $status  = "Success"
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
        $status  = "Failed"
        $message = $_.Exception.Message
    }

    # --- Update registry with result ---
    try {
        $updateConn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=$regServer;Database=$regDb;User Id=$user;Password=$pass;TrustServerCertificate=True;Encrypt=False;"
        )
        $updateConn.Open()
        $updateCmd = $updateConn.CreateCommand()
        $updateCmd.CommandText = "UPDATE dbo.ClientDeploymentRegistry SET LastDeployedAt = GETDATE(), LastDeployStatus = @s WHERE ClientId = @id"
        $updateCmd.Parameters.AddWithValue("@s",  $status)          | Out-Null
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
$failed  = $results | Where-Object { $_.Status -eq "Failed" }
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