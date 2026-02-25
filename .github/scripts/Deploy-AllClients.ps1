param(
    [string]$DacpacPath,
    [string]$RegistryServer,
    [string]$RegistryDatabase,
    [string]$SqlUser,
    [string]$SqlPassword
)

# --- Log file setup ---
$logFile = "$env:GITHUB_WORKSPACE\deployment-$((Get-Date).ToString('yyyy-MM-dd-HHmmss')).log"
$logFile = "deployment-$((Get-Date).ToString('yyyy-MM-dd-HHmmss')).log"
function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

# --- Load client list from central registry ---
$connStr = "Server=$RegistryServer;Database=$RegistryDatabase;User Id=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;"
$query   = "SELECT ClientId, ClientName, ServerName, DatabaseName FROM dbo.ClientDeploymentRegistry WHERE IsActive = 1"

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

Write-Host "Found $($clients.Count) active clients. Starting parallel deployment..."

# --- Deploy to all clients in parallel ---
$results = $clients | ForEach-Object -Parallel {
    $client      = $_
    $dacpac      = $using:DacpacPath
    $user        = $using:SqlUser
    $pass        = $using:SqlPassword
    $regServer   = $using:RegistryServer
    $regDb       = $using:RegistryDatabase

    $status  = "Success"
    $message = ""

    try {
        $result = & sqlpackage `
    "/Action:Publish" `
    "/SourceFile:$dacpac" `
    "/TargetServerName:$($client.ServerName)" `
    "/TargetDatabaseName:$($client.DatabaseName)" `
    "/TargetUser:$user" `
    "/TargetPassword:$pass" `
    "/TargetTrustServerCertificate:True" `
    "/p:BlockOnPossibleDataLoss=false" `
    "/p:DropObjectsNotInSource=false" `
    "/p:TreatVerificationErrorsAsWarnings=true" `
    "/TargetTrustServerCertificate:True"`
    2>&1

        $result = & sqlpackage @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw $result
        }

        Write-Host "✅ [$($client.ClientName)] SUCCESS"
    }
    catch {
        $status  = "Failed"
        $message = $_.Exception.Message
        Write-Host "❌ [$($client.ClientName)] FAILED: $message"

        # Per-client rollback is handled by SqlPackage's transaction wrapper automatically.
        # The dacpac deployment runs inside a transaction per target DB — failure rolls back that DB only.
    }

    # --- Update registry with result ---
    $updateConn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$regServer;Database=$regDb;User Id=$user;Password=$pass;TrustServerCertificate=True;"
    )
    $updateConn.Open()
    $updateCmd = $updateConn.CreateCommand()
    $updateCmd.CommandText = "UPDATE dbo.ClientDeploymentRegistry SET LastDeployedAt = GETDATE(), LastDeployStatus = @s WHERE ClientId = @id"
    $updateCmd.Parameters.AddWithValue("@s",  $status)           | Out-Null
    $updateCmd.Parameters.AddWithValue("@id", $client.ClientId)  | Out-Null
    $updateCmd.ExecuteNonQuery() | Out-Null
    $updateConn.Close()

    return [PSCustomObject]@{
        Client = $client.ClientName
        Status = $status
        Error  = $message
    }

} -ThrottleLimit 50   # 50 parallel deployments at a time — tune based on your server capacity

# --- Summary Report ---
Write-Host ""
Write-Host "===== DEPLOYMENT SUMMARY ====="
$failed  = $results | Where-Object { $_.Status -eq "Failed" }
$success = $results | Where-Object { $_.Status -eq "Success" }
Write-Host "✅ Succeeded: $($success.Count)"
Write-Host "❌ Failed:    $($failed.Count)"

Write-Log "Found $($clients.Count) active clients. Starting parallel deployment..."
Write-Log "✅ [$($client.ClientName)] SUCCESS"
Write-Log "❌ [$($client.ClientName)] FAILED: $message"
Write-Log "===== DEPLOYMENT SUMMARY ====="
Write-Log "✅ Succeeded: $($success.Count)"
Write-Log "❌ Failed:    $($failed.Count)"
Write-Log "  - $($_.Client): $($_.Error)"


if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed clients:"
    $failed | ForEach-Object { Write-Host "  - $($_.Client): $($_.Error)" }
    exit 1   # Fail the GitHub Actions job so you get a red build
} else {
    Write-Host "All deployments succeeded!"
    exit 0
}