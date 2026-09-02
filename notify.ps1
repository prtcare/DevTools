param(
    [string]$Type = "Claude Code",
    [string]$Message = "Needs attention",
    [ValidateSet("min", "low", "default", "high", "urgent")]
    [string]$Priority = "high",
    [string]$Project = "",
    [string]$Tags = ""
)

$topic = "nexus-dev-2026"

# ------------------------------------------------------------
# Determine notification style automatically
# ------------------------------------------------------------

$NotificationTitle = "Nexus - $Type"
$NotificationTags = $Tags

switch -Regex ($Type) {

    "Permission|Approval" {
        $Priority = "urgent"
        if (-not $NotificationTags) {
            $NotificationTags = "warning,lock"
        }
    }

    "Error|Failed|Failure" {
        $Priority = "urgent"
        if (-not $NotificationTags) {
            $NotificationTags = "rotating_light,x"
        }
    }

    "Complete|Completed|Success|Finished" {
        $Priority = "default"
        if (-not $NotificationTags) {
            $NotificationTags = "white_check_mark"
        }
    }

    "Attention|Input|Waiting" {
        $Priority = "high"
        if (-not $NotificationTags) {
            $NotificationTags = "bell"
        }
    }

    default {
        if (-not $NotificationTags) {
            $NotificationTags = "computer"
        }
    }
}

# ------------------------------------------------------------
# Add useful context
# ------------------------------------------------------------

$ComputerName = $env:COMPUTERNAME
$Time = Get-Date -Format "dd-MMM-yyyy HH:mm:ss"

$Body = $Message

if ($Project) {
    $Body += "`nProject: $Project"
}

$Body += "`nPC: $ComputerName"
$Body += "`nTime: $Time"

# ------------------------------------------------------------
# Send ntfy notification
# ------------------------------------------------------------

try {

    $Headers = @{
        "Title"    = $NotificationTitle
        "Priority" = $Priority
        "Tags"     = $NotificationTags
    }

    Invoke-RestMethod `
        -Uri "https://ntfy.sh/$topic" `
        -Method Post `
        -Headers $Headers `
        -Body $Body `
        -ContentType "text/plain; charset=utf-8" `
        -TimeoutSec 5 | Out-Null

}
catch {
    # Notification failure must never interrupt Claude Code
}

exit 0