#Requires -Version 5.1
<#
RunFileMaintenance.ps1
────────────────────────────────────────
• Lee especificaciones desde JSON (-JsonPath).
• Acciones: LIST, DELETE, COMPRESS (agrupa por día/semana/mes, opcional pwd).
• Log JSON Lines (script.log.json) con rotación 30 días.
#>

param (
    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$JsonPath
)

function Write-Log {
    param([string]$Level, [string]$Message)

    $log = Join-Path $PSScriptRoot 'script.log.json'

    # Rotación cada 30 días
    if (Test-Path $log) {
        $info = Get-Item $log
        if ($info.LastWriteTime -lt (Get-Date).AddDays(-30)) {
            $bak = "$log.$($info.LastWriteTime.ToString('yyyy-MM-dd')).bak"
            Rename-Item -Path $log -NewName $bak -Force
        }
    }

    @{timestamp=(Get-Date).ToString('o'); level=$Level; message=$Message} |
        ConvertTo-Json -Compress | Out-File -FilePath $log -Append -Encoding utf8
}

function Write-FilesLog {
    param(
        [string]$Action,
        [string]$Zip,
        [string[]]$Files
    )

    $log = Join-Path $PSScriptRoot 'script.log.json'

    @{timestamp=(Get-Date).ToString('o'); level='INFO'; action=$Action; zip=$Zip; files=$Files} |
        ConvertTo-Json -Compress | Out-File -FilePath $log -Append -Encoding utf8
}

function Load-Specs {
    param([string]$Path)
    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

function Find-Files {
    param($Spec)

    if (-not (Test-Path $Spec.Path)) {
        throw "Directorio no encontrado: $($Spec.Path)"
    }

    $cutOffDate = (Get-Date).Date.AddDays(-$Spec.Days)

    $files = Get-ChildItem -Path $Spec.Path -Filter ($Spec.Pattern ?? '*') -File -Recurse:($Spec.Recurse -eq $true) |
             Where-Object { $_.LastWriteTime.Date -le $cutOffDate }

    if ($Spec.Extension) {
        $extensions = $Spec.Extension | ForEach-Object { $_.TrimStart('.') }
        $files = $files | Where-Object { $extensions -contains $_.Extension.TrimStart('.') }
    }

    Write-Log INFO "Encontrados $($files.Count) archivos en $($Spec.Path)"
    return $files
}

function Delete-Files {
    param([array]$Files)

    foreach ($file in $Files) {
        try {
            Remove-Item $file.FullName -Force
            Write-Output $file.FullName
            Write-Log INFO "Archivo eliminado: $($file.FullName)"
        } catch {
            Write-Log ERROR "Error al borrar $($file.FullName): $($_.Exception.Message)"
        }
    }
}

function Get-PeriodStart {
    param([datetime]$Date, [string]$GroupBy)

    switch ($GroupBy.ToLower()) {
        'week'  { return $Date.Date.AddDays(-[int](($Date.DayOfWeek + 6) % 7)) }  # Lunes primer día
        'month' { return (Get-Date -Year $Date.Year -Month $Date.Month -Day 1) }
        default { return $Date.Date }
    }
}

function Compress-Files {
    param($Spec, [array]$Files)

    if (-not $Files) { return }

    $GroupBy = $Spec.GroupBy ?? 'day'

    $groups = $Files | Group-Object { (Get-PeriodStart -Date $_.LastWriteTime -GroupBy $GroupBy).ToString('yyyyMMdd') }

    foreach ($group in $groups) {
        $date    = $group.Name
        $folder  = Split-Path -Path $group.Group[0].FullName -Parent
        $zipPath = Join-Path $folder ("$date.zip")

        try {
            $filePaths = $group.Group | ForEach-Object { $_.FullName }

            $args = @('a', '-tzip', '-y', '-sdel')
            if ($Spec.Password) { $args += "-p$($Spec.Password)" }
            $args += $zipPath
            $args += $filePaths

            & 7z @args | Out-Null

            if ($LASTEXITCODE -ne 0) { throw "Error al ejecutar 7z para $zipPath" }

            Write-FilesLog 'COMPRESS' $zipPath $filePaths
        } catch {
            Write-Log ERROR "Error de compresión en el periodo ${date}: $($_.Exception.Message)"
        }
    }
}

try {
    Write-Log INFO 'Inicio de ejecución'
    $specs = Load-Specs -Path $JsonPath

    foreach ($spec in $specs) {
        try {
            $files = Find-Files -Spec $spec

            switch ($spec.Action.ToUpper()) {
                'LIST'     { $files.FullName }
                'DELETE'   { Delete-Files -Files $files }
                'COMPRESS' { Compress-Files -Spec $spec -Files $files }
                default    { Write-Log ERROR "Acción desconocida: $($spec.Action)" }
            }
        } catch {
            Write-Log ERROR "Error procesando especificación: $($_.Exception.Message)"
        }
    }
    Write-Log INFO 'Fin de ejecución'
} catch {
    Write-Log ERROR "Error fatal en el script: $($_.Exception.Message)"
    throw $_
}
