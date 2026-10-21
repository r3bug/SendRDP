# Windows PowerShell 5.1 / PowerShell 7. SYSTEM/admin diretti; UAC per avvio manuale non elevato.
# Default: irm 'https://pastebin.com/raw/ID' | iex
# Custom: & ([scriptblock]::Create((irm 'https://pastebin.com/raw/ID'))) --nome Infinity2024 --ip 192.168.10.202
# --anteprima: mostra la configurazione senza modificare file, registro o certificati.
# --verifica: controlla vincoli di sicurezza e client aperti, senza modifiche o elevazione.
& {
    param([object[]]$CliArguments)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    function Get-LaunchDecision {
        param([bool]$IsSystem, [bool]$IsAdmin, [bool]$Os64, [bool]$Process64, [int]$SessionId, [bool]$Preview)
        $elevate = -not $Preview -and -not ($IsSystem -or $IsAdmin)
        if ($elevate -and $SessionId -eq 0) {
            throw 'Sessione non interattiva senza privilegi amministrativi. Avvia PowerShell come amministratore oppure esegui il comando con NT AUTHORITY\SYSTEM.'
        }
        [pscustomobject]@{ Elevate=$elevate; Native64=($Os64 -and -not $Process64) }
    }

    function New-RelaunchScript {
        param([string]$Body, [object[]]$Arguments, [string]$LogPath)
        $argumentLiteral = '@(' + ((@($Arguments) | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ',') + ')'
        $logLiteral = "'" + $LogPath.Replace("'", "''") + "'"
        # Dati quotati come letterali, mai concatenati come comandi arbitrari.
        '$ErrorActionPreference = ''Stop''' + "`r`ntry {`r`n& {`r`n" + $Body +
            "`r`n} -CliArguments " + $argumentLiteral + ' *> ' + $logLiteral +
            "`r`nexit 0`r`n} catch {`r`n" +
            '[IO.File]::AppendAllText(' + $logLiteral + ', ($_ | Out-String))' + "`r`nexit 1`r`n}"
    }

    function Invoke-DeploymentRelaunch {
        param([string]$Body, [object[]]$Arguments, $Decision)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $tempDirectory = Join-Path $tempBase ('SendRDP-launch-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDirectory | Out-Null
        try {
            # Consente anche elevazione con un altro account amministratore.
            $launchAcl = [Security.AccessControl.DirectorySecurity]::new()
            $launchAcl.SetAccessRuleProtection($true, $false)
            $callerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            foreach ($sid in @($callerSid, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique) {
                $launchAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }
            Set-Acl -LiteralPath $tempDirectory -AclObject $launchAcl
            $launcher = Join-Path $tempDirectory 'launch.ps1'
            $outputLog = Join-Path $tempDirectory 'output.log'
            [IO.File]::WriteAllText($launcher, (New-RelaunchScript $Body $Arguments $outputLog), [Text.Encoding]::Unicode)
            $systemDirectory = if ($Decision.Native64) { 'Sysnative' } else { 'System32' }
            $powerShell = Join-Path $env:SystemRoot "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
            if ($Decision.Elevate) {
                Write-Host 'Richiesta elevazione Windows: conferma UAC o inserisci credenziali amministrative.'
                $process = Start-Process -FilePath $powerShell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '"') `
                    -Verb RunAs -WindowStyle Hidden -Wait -PassThru
                $exitCode = $process.ExitCode
            } else {
                Write-Host 'Passaggio al processo PowerShell a 64 bit; il PC resta acceso e le sessioni restano aperte.'
                & $powerShell -NoProfile -ExecutionPolicy Bypass -File $launcher
                $exitCode = $LASTEXITCODE
            }
            if (Test-Path -LiteralPath $outputLog) { Get-Content -LiteralPath $outputLog | ForEach-Object { Write-Host $_ } }
            if ($exitCode -ne 0) { throw "Deploy nel processo elevato/nativo non completato (codice $exitCode). Vedi il log sopra." }
        } finally {
            $resolved = [IO.Path]::GetFullPath($tempDirectory)
            if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
                (Split-Path -Leaf $resolved) -notmatch '^SendRDP-launch-[0-9a-f]{32}$') { throw 'Percorso temporaneo non valido.' }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }

    function Get-DeployConfig {
        param([object[]]$Arguments)
        $config = [ordered]@{
            NomeFile = 'Infinity2027'; Server = '192.168.10.201'
            Dominio = 'CONIGLIARO.local'; Anteprima = $false; Verifica = $false
            CancellaCredenzialiSalvate = $false
        }
        $seen = @{}
        for ($i = 0; $i -lt $Arguments.Count; $i++) {
            $option = ([string]$Arguments[$i]).ToLowerInvariant()
            $key = switch -Regex ($option) {
                '^--?(nome|nomefile)$' { 'NomeFile'; break }
                '^--?(ip|server)$' { 'Server'; break }
                '^--?dominio$' { 'Dominio'; break }
                '^--?(anteprima|whatif)$' { 'Anteprima'; break }
                '^--?verifica$' { 'Verifica'; break }
                '^--?cancella-credenziali-salvate$' { 'CancellaCredenzialiSalvate'; break }
                default { throw "Parametro sconosciuto: $option. Usa --nome, --ip, --dominio, --anteprima, --verifica, --cancella-credenziali-salvate." }
            }
            if ($seen.ContainsKey($key)) { throw "Parametro duplicato: $option" }
            $seen[$key] = $true
            if ($key -in @('Anteprima', 'Verifica', 'CancellaCredenzialiSalvate')) { $config[$key] = $true; continue }
            $i++
            if ($i -ge $Arguments.Count -or [string]$Arguments[$i] -match '^-') { throw "Manca il valore di $option." }
            $value = ([string]$Arguments[$i]).Trim()
            if ([string]::IsNullOrWhiteSpace($value)) { throw "Valore vuoto: $option" }
            $config[$key] = $value
        }
        if ($config.Anteprima -and $config.Verifica) { throw 'Usa --anteprima oppure --verifica, separatamente.' }
        # Avvio completamente predefinito: pulisce le credenziali degli utenti collegati.
        # Con qualunque argomento esplicito la pulizia richiede il relativo flag.
        if ($Arguments.Count -eq 0) { $config.CancellaCredenzialiSalvate = $true }
        $name = $config.NomeFile -replace '(?i)\.rdp$', ''
        if ($name.Length -gt 100 -or $name -match '[<>:"/\\|?*\x00-\x1f]' -or
            $name -match '[ .]$' -or $name -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)' -or
            [string]::IsNullOrWhiteSpace($name)) { throw 'Nome file non valido: specifica solo il nome, senza percorso.' }
        $config.NomeFile = $name + '.rdp'
        if ($config.Server -notmatch '^(?<host>[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?)(?::(?<port>[0-9]{1,5}))?$') {
            throw 'Server non valido. Usa IPv4 o nome DNS, eventualmente seguito da :porta.'
        }
        $serverHost = $Matches.host
        $portText = $Matches['port']
        if ($serverHost.Length -gt 253 -or $serverHost.Contains('..')) { throw 'Nome server non valido.' }
        if ($portText -and ([int]$portText -lt 1 -or [int]$portText -gt 65535)) { throw 'Porta non valida.' }
        if ($serverHost -match '^[0-9.]+$') {
            $ip = $null
            if ($serverHost -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
                -not [Net.IPAddress]::TryParse($serverHost, [ref]$ip)) { throw 'IPv4 non valido.' }
        }
        if ($config.Dominio.Length -gt 253 -or $config.Dominio -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$' -or
            $config.Dominio.Contains('..')) { throw 'Dominio non valido.' }
        # Il prompt RDP collaudato usa il dominio DNS e il prefisso NetBIOS separati.
        $config['NetBiosDominio'] = ($config.Dominio -split '\.')[0]
        $config['ServerHost'] = $serverHost
        [pscustomobject]$config
    }

    function Read-RdpMachinePolicySnapshot {
        # La vista nativa e esplicita anche nella verifica avviata da PowerShell a 32 bit.
        $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
        $values = @{}; $deniedTargets = @(); $readErrors = [Collections.Generic.List[string]]::new()
        $baseKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $requests = @(
                @{ Path='SYSTEM\CurrentControlSet\Control\Lsa'; Names=@('DisableDomainCreds') }
                @{ Path='SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'; Names=@('RestrictedRemoteAdministration', 'DenySavedCredentials') }
                @{ Path='SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\DenySavedCredentials'; Names=@(); List=$true }
            )
            foreach ($request in $requests) {
                $key = $null
                try {
                    $key = $baseKey.OpenSubKey($request.Path, $false)
                    foreach ($name in $request.Names) {
                        $values[$name] = if ($null -ne $key) { $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
                    }
                    if ($request.ContainsKey('List') -and $null -ne $key) {
                        # Non ignorare voci nominate manualmente: una lista incerta va segnalata.
                        foreach ($name in $key.GetValueNames()) { $deniedTargets += [string]$key.GetValue($name) }
                    }
                } catch { $readErrors.Add("Registro $($request.Path): $($_.Exception.Message)") }
                finally { if ($null -ne $key) { $key.Dispose() } }
            }
        } catch { $readErrors.Add("Registro computer: $($_.Exception.Message)") }
        finally { if ($null -ne $baseKey) { $baseKey.Dispose() } }
        [pscustomobject]@{ Values=$values; DeniedTargets=@($deniedTargets); Errors=$readErrors.ToArray(); RegistryView=[string]$view }
    }

    function Resolve-RdpReadiness {
        param(
            [string]$ServerHost,
            [ValidateSet('Running', 'NotRunning', 'Unknown')][string]$CredentialGuard,
            [hashtable]$PolicyValues = @{}, [string[]]$DeniedTargets = @(),
            [object[]]$MstscProcesses = @(), [string[]]$QueryErrors = @(),
            [string]$RegistryView = ''
        )
        # Valutazione pura: non cambia policy, processi, servizi o sessioni.
        $reasons = [Collections.Generic.List[object]]::new()
        if ($CredentialGuard -eq 'Running') {
            $reasons.Add([pscustomobject]@{ Code='CredentialGuard'; Message='Credential Guard e in esecuzione: puo impedire il riuso delle password RDP salvate. Non viene disattivato; verificare l''accesso con password inserita dall''utente.' })
        } elseif ($CredentialGuard -eq 'Unknown') {
            $reasons.Add([pscustomobject]@{ Code='CredentialGuardUnknown'; Message='Stato Credential Guard non determinato: il riuso delle credenziali salvate deve essere verificato sul client.' })
        }
        if ($PolicyValues['DisableDomainCreds'] -eq 1) {
            $reasons.Add([pscustomobject]@{ Code='DisableDomainCreds'; Message='DisableDomainCreds=1: Windows vieta la memorizzazione di credenziali di rete. Verificare la policy aziendale; il deploy non la disattiva.' })
        }
        if ($null -ne $PolicyValues['RestrictedRemoteAdministration'] -and $PolicyValues['RestrictedRemoteAdministration'] -ne 0) {
            $reasons.Add([pscustomobject]@{ Code='RestrictedRemoteAdministration'; Message="RestrictedRemoteAdministration=$($PolicyValues['RestrictedRemoteAdministration']): una policy puo imporre Remote Credential Guard/Restricted Admin. Verificarne la compatibilita con il server e con le credenziali richieste." })
        }
        $matchedDenyTargets = @(); $unresolvedDenyTargets = @()
        if ($PolicyValues['DenySavedCredentials'] -eq 1) {
            foreach ($entry in $DeniedTargets) {
                $pattern = ([string]$entry).Trim()
                # CredSSP documenta solo l'asterisco come wildcard, al massimo uno.
                # Non interpretare ?, [] o altri caratteri come wildcard PowerShell.
                if ($pattern -notmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9.*:_-]+$' -or ([regex]::Matches($pattern, '\*')).Count -gt 1) {
                    $unresolvedDenyTargets += $pattern
                    continue
                }
                $expression = '^' + [regex]::Escape($pattern).Replace('\*', '.*') + '$'
                if ([regex]::IsMatch("TERMSRV/$ServerHost", $expression, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $matchedDenyTargets += $pattern }
            }
            if ($matchedDenyTargets.Count) {
                $reasons.Add([pscustomobject]@{ Code='DenySavedCredentials'; Message="DenySavedCredentials vieta la delega al server richiesto: $($matchedDenyTargets -join ', '). La regola di divieto deve essere verificata nella policy aziendale." })
            }
            if (-not $DeniedTargets.Count -or $unresolvedDenyTargets.Count) {
                $reasons.Add([pscustomobject]@{ Code='DenySavedCredentialsUnknown'; Message='DenySavedCredentials e attiva ma la lista e vuota, illeggibile o contiene voci non interpretabili: non e possibile escludere un blocco delle password salvate.' })
            }
        }
        if ($QueryErrors.Count) {
            $reasons.Add([pscustomobject]@{ Code='DiagnosticIncomplete'; Message='Diagnostica incompleta: alcuni controlli non sono leggibili. Consultare QueryErrors nel rapporto; non considerare il client gia validato.' })
        }
        [pscustomobject]@{
            ServerHost=$ServerHost; CredentialGuard=$CredentialGuard; Policies=$PolicyValues
            DeniedTargets=@($DeniedTargets); MatchedDenyTargets=@($matchedDenyTargets)
            MstscProcesses=@($MstscProcesses); QueryErrors=@($QueryErrors); RegistryView=$RegistryView
            Status=$(if ($reasons.Count) { 'Attention' } else { 'NoKnownBlockers' }); Reasons=$reasons.ToArray()
        }
    }

    function Get-RdpReadiness {
        param([string]$ServerHost)
        $snapshot = Read-RdpMachinePolicySnapshot
        $queryErrors = [Collections.Generic.List[string]]::new()
        foreach ($message in $snapshot.Errors) { $queryErrors.Add($message) }
        $credentialGuard = 'Unknown'
        try {
            $guard = @(Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -OperationTimeoutSec 10 -ErrorAction Stop)
            if ($guard.Count -ne 1 -or $null -eq $guard[0].SecurityServicesRunning) { throw 'SecurityServicesRunning non disponibile.' }
            $credentialGuard = if (@($guard[0].SecurityServicesRunning) -contains 1) { 'Running' } else { 'NotRunning' }
        } catch { $queryErrors.Add("Credential Guard: $($_.Exception.Message)") }
        $mstsc = @()
        try {
            $mstsc = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='mstsc.exe'" -OperationTimeoutSec 10 -ErrorAction Stop |
                ForEach-Object { [pscustomobject]@{ PID=[int]$_.ProcessId; SessionId=[int]$_.SessionId } })
        } catch { $queryErrors.Add("Processi mstsc: $($_.Exception.Message)") }
        Resolve-RdpReadiness -ServerHost $ServerHost -CredentialGuard $credentialGuard -PolicyValues $snapshot.Values `
            -DeniedTargets $snapshot.DeniedTargets -MstscProcesses $mstsc -QueryErrors $queryErrors.ToArray() -RegistryView $snapshot.RegistryView
    }

    function Write-RdpReadiness {
        param($Readiness)
        Write-Host "Diagnostica client: Credential Guard=$($Readiness.CredentialGuard); vista registro=$($Readiness.RegistryView)."
        foreach ($reason in $Readiness.Reasons) { Write-Warning $reason.Message }
        foreach ($message in $Readiness.QueryErrors) { Write-Warning $message }
        if ($Readiness.MstscProcesses.Count) {
            $sessions = @($Readiness.MstscProcesses | ForEach-Object { "PID $($_.PID)/sessione $($_.SessionId)" })
            Write-Host "Finestre/processi RDP gia aperti: $($sessions -join ', '). Il deploy li lascia attivi."
        }
        if ($Readiness.Status -eq 'NoKnownBlockers') {
            Write-Host 'Nessuno dei blocchi locali controllati e stato rilevato. Resta da provare la connessione reale con le policy utente e server.'
        }
        Write-Host 'Usare il nuovo file RDP per una nuova connessione. Una finestra RDP gia aperta puo conservare impostazioni precedenti; non viene chiusa automaticamente.'
    }

    function Get-RdpLines {
        param($Config)
        @(
            "full address:s:$($Config.Server)"
            # Mantiene il comportamento del collegamento RDP storico: dominio DNS
            # separato e prefisso NetBIOS gia presente nel nome utente.
            "domain:s:$($Config.Dominio)"
            "username:s:$($Config.NetBiosDominio)\"
            'prompt for credentials:i:0'
            'promptcredentialonce:i:1'
            'enablecredsspsupport:i:1'
            'negotiate security layer:i:1'
            # Come nello script originale: niente avviso certificato server per questa connessione.
            'authentication level:i:0'
            'screen mode id:i:2'
            'use multimon:i:1'
            'session bpp:i:32'
            'autoreconnection enabled:i:1'
            'redirectclipboard:i:1'
            'redirectprinters:i:1'
            'drivestoredirect:s:*'
            'redirectcomports:i:1'
            'redirectsmartcards:i:1'
            'redirectposdevices:i:1'
            'devicestoredirect:s:*'
            'usbdevicestoredirect:s:*'
            'audiomode:i:0'
            'audiocapturemode:i:1'
            'camerastoredirect:s:*'
            'redirectwebauthn:i:1'
            'redirectlocation:i:1'
        )
    }

    function Set-DeploymentRegistryValue {
        param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
        $oldValue = $null; $oldType = $null; $existed = $false
        if (Test-Path -LiteralPath $Path) {
            $key = Get-Item -LiteralPath $Path
            try {
                $existed = $key.GetValueNames() -contains $Name
                if ($existed) {
                    $oldValue = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $oldType = [string]$key.GetValueKind($Name)
                }
            } finally { $key.Close() }
        }
        # Journal scritto PRIMA della modifica, per il ripristino manuale.
        [pscustomobject]@{ Path=$Path; Name=$Name; Existed=$existed; OldValue=$oldValue; OldType=$oldType; NewValue=$Value } |
            ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath $script:RegistryJournal -Encoding UTF8
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        # Controlla subito il valore effettivo; nessuna attesa di gpupdate o riavvio.
        $verifyKey = Get-Item -LiteralPath $Path
        try {
            $written = $verifyKey.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $writtenType = [string]$verifyKey.GetValueKind($Name)
            if ($writtenType -ne $Type -or [string]$written -cne [string]$Value) {
                throw "Verifica registro fallita: $Path -> $Name. Una policy potrebbe avere ripristinato il valore."
            }
        } finally { $verifyKey.Close() }
    }

    function Add-SavedCredentialTarget {
        param([string]$ServerHost)
        $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
        foreach ($policy in @('AllowSavedCredentials', 'AllowSavedCredentialsWhenNTLMOnly')) {
            Set-DeploymentRegistryValue $base $policy 1
            $path = Join-Path $base $policy
            $values = @{}
            if (Test-Path -LiteralPath $path) {
                $key = Get-Item -LiteralPath $path
                try { foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) } }
                finally { $key.Close() }
            }
            $target = "TERMSRV/$ServerHost"
            if ($values.Values -notcontains $target) {
                $index = 1
                while ($values.ContainsKey([string]$index)) { $index++ }
                Set-DeploymentRegistryValue $path ([string]$index) $target 'String'
            }
        }
        # Non ampliare la delega a TERMSRV/* e non cancellare liste preesistenti.
        $deny = Get-ItemProperty -LiteralPath $base
        if ($deny.PSObject.Properties['DenySavedCredentials'] -and $deny.DenySavedCredentials -eq 1) {
            Write-Warning 'Una policy DenySavedCredentials e attiva: puo impedire il riuso delle password.'
        }
    }

    function Expand-UserDesktop {
        param([string]$Value, [string]$ProfilePath, [hashtable]$UserEnvironment)
        $profileRoot = [IO.Path]::GetPathRoot($ProfilePath)
        $map = @{
            HOMEDRIVE = $profileRoot.TrimEnd('\')
            HOMEPATH = $ProfilePath.Substring($profileRoot.Length - 1)
            PUBLIC = [Environment]::GetEnvironmentVariable('PUBLIC')
            SYSTEMDRIVE = [Environment]::GetEnvironmentVariable('SystemDrive')
            SYSTEMROOT = [Environment]::GetEnvironmentVariable('SystemRoot')
            PROGRAMDATA = [Environment]::GetEnvironmentVariable('ProgramData')
        }
        foreach ($name in $UserEnvironment.Keys) { $map[$name] = $UserEnvironment[$name] }
        # ProfileList e' la fonte autorevole; mai USERPROFILE del processo SYSTEM
        # o un valore volatile rimasto da un precedente spostamento del profilo.
        $map['USERPROFILE'] = $ProfilePath
        $expanded = $Value
        for ($pass = 0; $pass -lt 8; $pass++) {
            $previous = $expanded
            $expanded = [regex]::Replace($expanded, '%([^%]+)%', [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                $name = $match.Groups[1].Value
                if ($map.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$map[$name])) {
                    return [string]$map[$name]
                }
                return $match.Value
            })
            if ($expanded -eq $previous) { break }
        }
        # Accetta anche un Desktop posto direttamente su \\server\share.
        if ($expanded -match '%[^%]+%' -or
            $expanded -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+(?:\\|$))' -or
            $expanded.StartsWith('\\?\') -or $expanded.StartsWith('\\.\')) {
            throw "Desktop non risolvibile per ${ProfilePath}: $Value"
        }
        [IO.Path]::GetFullPath($expanded)
    }

    function Read-UserHiveValues {
        param([string]$MountName, [string]$SubKey)
        $values = @{}
        $key = [Microsoft.Win32.Registry]::Users.OpenSubKey("$MountName\$SubKey")
        if ($null -ne $key) {
            try {
                foreach ($name in $key.GetValueNames()) {
                    $values[$name] = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
            } finally { $key.Dispose() }
        }
        return $values
    }

    function Get-UserHiveChildNames {
        param([string]$MountName, [string]$SubKey)
        $key = [Microsoft.Win32.Registry]::Users.OpenSubKey("$MountName\$SubKey")
        if ($null -ne $key) {
            try { $key.GetSubKeyNames() } finally { $key.Dispose() }
        }
    }

    function Resolve-OneDriveEnvironment {
        param([hashtable]$UserEnvironment, [object[]]$Accounts)
        $resolved = @{}
        foreach ($name in $UserEnvironment.Keys) { $resolved[$name] = $UserEnvironment[$name] }
        $folders = @($Accounts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.UserFolder) })
        $candidates = @{
            OneDriveConsumer = @($folders | Where-Object { $_.Name -eq 'Personal' } | ForEach-Object { $_.UserFolder } | Select-Object -Unique)
            OneDriveCommercial = @($folders | Where-Object { $_.Name -match '^Business[0-9]+$' } | ForEach-Object { $_.UserFolder } | Select-Object -Unique)
            OneDrive = @($folders | ForEach-Object { $_.UserFolder } | Select-Object -Unique)
        }
        foreach ($name in $candidates.Keys) {
            # Piu account aziendali: non scegliere una cartella per tentativi.
            if ([string]::IsNullOrWhiteSpace([string]$resolved[$name]) -and $candidates[$name].Count -eq 1) {
                $resolved[$name] = $candidates[$name][0]
            }
        }
        return $resolved
    }

    function Resolve-UserDesktopPaths {
        param([string]$ProfilePath, [hashtable]$UserEnvironment, [hashtable]$UserShellFolders, [hashtable]$ShellFolders)
        $paths = [Collections.Generic.List[string]]::new()
        $paths.Add((Join-Path $ProfilePath 'Desktop'))
        $desktopNames = @('Desktop', '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}')
        $configured = @($desktopNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$UserShellFolders[$_]) })
        $source = $UserShellFolders
        if ($configured.Count -eq 0) {
            # Shell Folders e' una cache: usarla solo se manca la configurazione corrente.
            $source = $ShellFolders
            $configured = @($desktopNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$source[$_]) })
        }
        foreach ($name in $configured) { $paths.Add((Expand-UserDesktop ([string]$source[$name]) $ProfilePath $UserEnvironment)) }
        $paths.ToArray() | Select-Object -Unique
    }

    function Invoke-ProfileHiveCommand {
        param([ValidateSet('load', 'unload')][string]$Operation, [string]$MountName, [string]$HiveFile)
        $nativeArguments = @($Operation, "HKU\$MountName")
        if ($Operation -eq 'load') { $nativeArguments += $HiveFile }
        # reg.exe scrive gli errori su stderr: raccoglili senza saltare la gestione della race con il logon.
        $ErrorActionPreference = 'Continue'
        $output = @(& "$env:SystemRoot\System32\reg.exe" @nativeArguments 2>&1)
        [pscustomobject]@{ ExitCode=$LASTEXITCODE; Message=($output -join ' ') }
    }

    function Get-UserDesktops {
        param([string]$Sid, [string]$ProfilePath, [bool]$DefaultProfile = $false)
        $mountName = $Sid
        $mounted = $false
        $desktops = @()
        try {
            if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$mountName")) {
                $hiveFile = Join-Path $ProfilePath 'NTUSER.DAT'
                if (-not (Test-Path -LiteralPath $hiveFile)) { throw "Hive utente assente o non accessibile: $hiveFile" }
                $mountName = 'SendRDP_' + [guid]::NewGuid().ToString('N')
                $loadResult = Invoke-ProfileHiveCommand 'load' $mountName $hiveFile
                if ($loadResult.ExitCode -eq 0) { $mounted = $true }
                elseif (Test-Path -LiteralPath "Registry::HKEY_USERS\$Sid") {
                    # Il servizio profili puo avere caricato l'hive dopo il primo controllo.
                    $mountName = $Sid
                } else {
                    throw "Impossibile caricare il profilo $Sid da $hiveFile (reg.exe $($loadResult.ExitCode)): $($loadResult.Message)"
                }
            }
            if ($mounted) {
                [pscustomobject]@{ Mount=$mountName; HiveFile=$hiveFile } | ConvertTo-Json -Compress |
                    Add-Content -LiteralPath (Join-Path $script:RunDirectory 'hives.jsonl') -Encoding UTF8
            }
            $root = "Registry::HKEY_USERS\$mountName"
            Set-DeploymentRegistryValue "$root\Software\Policies\Microsoft\Windows NT\Terminal Services" 'DisablePasswordSaving' 0
            if (-not $DefaultProfile) {
                $userEnv = @{}
                foreach ($subKey in @('Environment', 'Volatile Environment')) {
                    $values = Read-UserHiveValues $mountName $subKey
                    foreach ($name in $values.Keys) { $userEnv[$name] = $values[$name] }
                }
                $sessionValues = @{}
                foreach ($session in @(Get-UserHiveChildNames $mountName 'Volatile Environment')) {
                    $values = Read-UserHiveValues $mountName "Volatile Environment\$session"
                    foreach ($name in $values.Keys) {
                        if (-not $sessionValues.ContainsKey($name)) { $sessionValues[$name] = @() }
                        $sessionValues[$name] += [string]$values[$name]
                    }
                }
                foreach ($name in $sessionValues.Keys) {
                    $unique = @($sessionValues[$name] | Select-Object -Unique)
                    if (-not $userEnv.ContainsKey($name) -and $unique.Count -eq 1) { $userEnv[$name] = $unique[0] }
                }
                $accountKey = 'Software\Microsoft\OneDrive\Accounts'
                $accounts = @(foreach ($accountName in @(Get-UserHiveChildNames $mountName $accountKey)) {
                    $values = Read-UserHiveValues $mountName "$accountKey\$accountName"
                    [pscustomobject]@{ Name=$accountName; UserFolder=[string]$values['UserFolder'] }
                })
                $userEnv = Resolve-OneDriveEnvironment $userEnv $accounts
                $shellKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer'
                $userShell = Read-UserHiveValues $mountName "$shellKey\User Shell Folders"
                $shell = Read-UserHiveValues $mountName "$shellKey\Shell Folders"
                $desktops = @(Resolve-UserDesktopPaths $ProfilePath $userEnv $userShell $shell)
            }
        } finally {
            if ($mounted) {
                # Non scaricare mai gli hive caricati da Windows o da un'altra esecuzione.
                for ($attempt = 0; $attempt -lt 3; $attempt++) {
                    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
                    $unloadResult = Invoke-ProfileHiveCommand 'unload' $mountName
                    if ($unloadResult.ExitCode -eq 0) { break }
                    if ($attempt -lt 2) { Start-Sleep -Milliseconds 150 }
                }
                if ($unloadResult.ExitCode -ne 0) {
                    throw "Impossibile scaricare HKU\$mountName ($hiveFile): $($unloadResult.Message). Verificare prima di rilanciare."
                }
            }
        }
        $desktops | Select-Object -Unique
    }

    function Protect-AndSignRdp {
        param([string]$Path)
        $subject = 'CN=SendRDP Local Publisher'
        $certificate = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
            $_.Subject -eq $subject -and $_.FriendlyName -eq 'SendRDP managed publisher' -and
            $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30)
        } | Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($null -eq $certificate) {
            $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
                -FriendlyName 'SendRDP managed publisher' -CertStoreLocation Cert:\LocalMachine\My `
                -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable `
                -NotAfter (Get-Date).AddYears(3)
        }
        # Importa solo la parte pubblica: la chiave privata rimane nel computer che genera il file.
        $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate.RawData)
        foreach ($storeName in @('Root', 'TrustedPublisher')) {
            $store = [Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
            try { $store.Open('ReadWrite'); $store.Add($publicCertificate) } finally { $store.Close() }
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $sha256 = ([BitConverter]::ToString($sha.ComputeHash($certificate.RawData))).Replace('-', '') }
        finally { $sha.Dispose() }
        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        $existing = Get-ItemProperty -LiteralPath $policy
        $trusted = @()
        if ($existing.PSObject.Properties['TrustedCertThumbprints']) {
            $trusted = @(([string]$existing.TrustedCertThumbprints -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $trusted += "sha256:$sha256"
        $admx = Join-Path $env:SystemRoot 'PolicyDefinitions\TerminalServer.admx'
        $supportsSha2 = (Test-Path -LiteralPath $admx) -and (([IO.File]::ReadAllText($admx)) -match 'DisableSHA1CertThumbprints')
        if (-not $supportsSha2) { $trusted += $certificate.Thumbprint }
        Set-DeploymentRegistryValue $policy 'TrustedCertThumbprints' (($trusted | Select-Object -Unique) -join ',') 'String'
        [pscustomobject]@{ Thumbprint=$certificate.Thumbprint; Sha256=$sha256; Expires=$certificate.NotAfter } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:RunDirectory 'publisher.json') -Encoding UTF8
        # /sha256 sceglie l'algoritmo di firma; l'identificatore richiesto e' Certificate.Thumbprint.
        & "$env:SystemRoot\System32\rdpsign.exe" /sha256 $certificate.Thumbprint $Path | Out-Host
        if ($LASTEXITCODE -ne 0 -or -not ([IO.File]::ReadAllText($Path) -match '(?m)^signature:s:')) {
            throw 'Firma RDP non riuscita. Nessun vecchio RDP e stato cancellato.'
        }
    }

    function Publish-RdpFile {
        param([string]$Stage, [string]$TargetPath, [string[]]$Desktops, [string]$RunDirectory)
        $oldFiles = [Collections.Generic.List[object]]::new()
        $failures = [Collections.Generic.List[string]]::new()
        foreach ($desktop in @($Desktops | Select-Object -Unique)) {
            try {
                if (-not (Test-Path -LiteralPath $desktop)) {
                    if ($desktop.StartsWith('\\')) { throw "Desktop di rete non accessibile: $desktop" }
                    Write-Warning "Desktop non presente: $desktop"
                    continue
                }
                # Solo file direttamente sul Desktop: nessuna cancellazione ricorsiva.
                foreach ($file in @(Get-ChildItem -LiteralPath $desktop -Filter '*.rdp' -File -Force)) { $oldFiles.Add($file) }
            } catch {
                if ($desktop -ieq (Split-Path -Parent $TargetPath)) { throw }
                $failures.Add("$desktop : $($_.Exception.Message)")
            }
        }
        $manifest = @()
        $backupIndex = 0
        foreach ($file in @($oldFiles | Sort-Object FullName -Unique)) {
            try {
                # I placeholder OneDrive possono avere ReparsePoint senza essere link simbolici.
                if ($file.LinkType) { throw "RDP link non supportato: $($file.FullName)" }
                $backup = Join-Path $RunDirectory (('{0:D5}' -f $backupIndex) + '.rdp')
                $backupIndex++
                Copy-Item -LiteralPath $file.FullName -Destination $backup
                $hash = (Get-FileHash -LiteralPath $backup).Hash
                if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne $hash) { throw "Verifica backup fallita: $($file.FullName)" }
                $manifest += [pscustomobject]@{ Original=$file.FullName; Backup=$backup; Hash=$hash }
            } catch {
                # Non sovrascrivere il target precedente senza il suo backup.
                if ($file.FullName -ieq $TargetPath) { throw }
                $failures.Add("Backup $($file.FullName): $($_.Exception.Message). File conservato.")
            }
        }
        ConvertTo-Json -InputObject @($manifest) -Depth 5 | Set-Content -LiteralPath (Join-Path $RunDirectory 'files.json') -Encoding UTF8
        # Pubblica prima della pulizia. La copia eredita i permessi del Desktop pubblico.
        New-Item -ItemType Directory -Path (Split-Path -Parent $TargetPath) -Force | Out-Null
        Copy-Item -LiteralPath $Stage -Destination $TargetPath -Force
        if ((Get-FileHash -LiteralPath $TargetPath).Hash -ne (Get-FileHash -LiteralPath $Stage).Hash) { throw 'Verifica del file pubblicato fallita.' }
        foreach ($entry in $manifest) {
            if ($entry.Original -ieq $TargetPath) { continue }
            try {
                if ((Get-FileHash -LiteralPath $entry.Original).Hash -ne $entry.Hash) { throw 'File cambiato dopo il backup.' }
                Remove-Item -LiteralPath $entry.Original -Force
            } catch { $failures.Add("$($entry.Original): $($_.Exception.Message)") }
        }
        if ($failures.Count) {
            $failures | Set-Content -LiteralPath (Join-Path $RunDirectory 'cleanup-errors.txt') -Encoding UTF8
            throw "Nuovo RDP pubblicato, ma pulizia incompleta: $($failures -join '; ')"
        }
        Write-Host "RDP pubblico pubblicato: $TargetPath - $($manifest.Count) vecchi file salvati nel backup."
    }

    function Initialize-DeploymentWorkspace {
        param($Config)
        $dataRoot = Join-Path $env:ProgramData 'SendRDP'
        if (Test-Path -LiteralPath $dataRoot) {
            if ((Get-Item -LiteralPath $dataRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "La cartella di lavoro non puo essere un link: $dataRoot" }
        } else { New-Item -ItemType Directory -Path $dataRoot | Out-Null }
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $dataRoot -AclObject $acl
        $script:RunDirectory = Join-Path $dataRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:RunDirectory | Out-Null
        $script:RegistryJournal = Join-Path $script:RunDirectory 'registry.jsonl'
        $config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:RunDirectory 'config.json') -Encoding UTF8
        Write-Host "Backup e diagnostica: $script:RunDirectory"
    }

    function Remove-SavedCredentialsFromInteractiveUsers {
        param([string]$ServerHost)
        if (-not ('SendRdpUserProcess' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SendRdpUserProcess {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars;
        public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow;
        public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION {
        public IntPtr hProcess; public IntPtr hThread; public int processId; public int threadId;
    }
    [DllImport("wtsapi32.dll", SetLastError=true)] static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool CreateProcessAsUser(
        IntPtr token, string app, string command, IntPtr pa, IntPtr ta, bool inherit, uint flags,
        IntPtr environment, string directory, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    public static int Run(uint sessionId, string commandLine) {
        IntPtr token;
        if (!WTSQueryUserToken(sessionId, out token)) return -1000 - Marshal.GetLastWin32Error();
        try {
            STARTUPINFO si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(si);
            si.lpDesktop = "winsta0\\default";
            si.dwFlags = 1;
            si.wShowWindow = 0;
            PROCESS_INFORMATION pi;
            bool ok = CreateProcessAsUser(token, null, commandLine, IntPtr.Zero, IntPtr.Zero, false, 0x08000000,
                IntPtr.Zero, Environment.GetFolderPath(Environment.SpecialFolder.System), ref si, out pi);
            if (!ok) return -2000 - Marshal.GetLastWin32Error();
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
            return 0;
        } finally { CloseHandle(token); }
    }
}
'@
        }
        $sessions = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            ForEach-Object { [int]$_.SessionId } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
        if (-not $sessions.Count) {
            Write-Warning "Nessun utente interattivo collegato: impossibile cancellare TERMSRV/$ServerHost."
            return
        }
        $target = "TERMSRV/$ServerHost"
        $results = [Collections.Generic.List[object]]::new()
        $currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
        foreach ($session in $sessions) {
            if (-not $isSystem -and $session -eq $currentSession) {
                & "$env:SystemRoot\System32\cmdkey.exe" "/delete:$target" | Out-Host
                $exitCode = $LASTEXITCODE
            } else {
                $command = "`"$env:SystemRoot\System32\cmdkey.exe`" /delete:$target"
                $exitCode = [SendRdpUserProcess]::Run([uint32]$session, $command)
            }
            $results.Add([pscustomobject]@{ SessionId=$session; Target=$target; ExitCode=$exitCode })
            if ($exitCode -ne 0) {
                Write-Warning "Nessuna credenziale $target rimossa nella sessione $session (cmdkey codice $exitCode). Il deploy continua."
            } else {
                Write-Host "Credenziale salvata rimossa per $target nella sessione $session."
            }
        }
        $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:RunDirectory 'credential-cleanup.json') -Encoding UTF8
    }

    function Set-RdpMachineConfiguration {
        param($Config)
        $ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        Set-DeploymentRegistryValue $ts 'DisablePasswordSaving' 0
        Add-SavedCredentialTarget $config.ServerHost
        # Compatibilita con client aprile-giugno 2026. La firma resta il meccanismo principale.
        Set-DeploymentRegistryValue "$ts\Client" 'RedirectionWarningDialogVersion' 1
    }

    function Update-RdpUserProfiles {
        param([string]$PublicDesktop)
        $desktops = [Collections.Generic.List[string]]::new()
        $desktops.Add($publicDesktop)
        $profileErrors = [Collections.Generic.List[string]]::new()
        $profileReport = [Collections.Generic.List[object]]::new()
        $profilesKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        foreach ($profileKey in Get-ChildItem -LiteralPath $profilesKey) {
            if ($profileKey.PSChildName -notmatch '^S-1-(5-21|12-1)-[0-9-]+$') { continue }
            $profilePath = ''
            try {
                $profile = Get-ItemProperty -LiteralPath $profileKey.PSPath
                $profilePath = [Environment]::ExpandEnvironmentVariables($profile.ProfileImagePath)
                if (-not (Test-Path -LiteralPath $profilePath)) { throw "Profilo registrato ma assente: $profilePath" }
                $profileDesktops = @(Get-UserDesktops $profileKey.PSChildName $profilePath)
                foreach ($desktop in $profileDesktops) { $desktops.Add($desktop) }
                $profileReport.Add([pscustomobject]@{ SID=$profileKey.PSChildName; Profile=$profilePath; Status='OK'; Desktops=$profileDesktops })
                Write-Host "Profilo $($profileKey.PSChildName): $($profileDesktops -join '; ')"
            } catch {
                $message = "$($profileKey.PSChildName) ($profilePath): $($_.Exception.Message)"
                $profileErrors.Add($message)
                $profileReport.Add([pscustomobject]@{ SID=$profileKey.PSChildName; Profile=$profilePath; Status='ERROR'; Error=$_.Exception.Message })
                Write-Warning $message
            }
        }
        $defaultPath = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath $profilesKey).Default)
        try { Get-UserDesktops 'SendRDP_DefaultTemplate' $defaultPath $true | Out-Null }
        catch { $profileErrors.Add("Profilo Default: $($_.Exception.Message)"); Write-Warning $profileErrors[$profileErrors.Count - 1] }
        ConvertTo-Json -InputObject @($profileReport.ToArray()) -Depth 6 |
            Set-Content -LiteralPath (Join-Path $script:RunDirectory 'profiles.json') -Encoding UTF8
        if ($profileErrors.Count) { $profileErrors | Set-Content -LiteralPath (Join-Path $script:RunDirectory 'profile-errors.txt') -Encoding UTF8 }
        [pscustomobject]@{ Desktops=$desktops.ToArray(); Errors=$profileErrors.ToArray() }
    }

    function Invoke-RdpDeployment {
        param($Config, [string]$PublicDesktop, [string]$TargetPath, [string[]]$RdpLines, $Readiness)
        Get-Command New-SelfSignedCertificate, "$env:SystemRoot\System32\rdpsign.exe" -ErrorAction Stop | Out-Null
        Write-Host '[1/5] Preparo backup e diagnostica.'
        Initialize-DeploymentWorkspace $Config
        $Readiness | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath (Join-Path $script:RunDirectory 'readiness.json') -Encoding UTF8
        $result = [ordered]@{
            Status='InProgress'; Target=$TargetPath; ComputerRestartRequested=$false
            ExistingSessionsModified=$false; AppliesTo='NewRdpClientConnection'
            Started=(Get-Date).ToString('o'); Finished=$null; Error=$null
        }
        try {
            Write-Host '[2/5] Applico e verifico le impostazioni client.'
            if ($Config.CancellaCredenzialiSalvate) {
                Write-Host '[2/5] Cancello le credenziali RDP salvate dagli utenti collegati.'
                Remove-SavedCredentialsFromInteractiveUsers $Config.ServerHost
            }
            Set-RdpMachineConfiguration $Config
            Write-Host '[3/5] Aggiorno i profili e individuo i Desktop.'
            $profiles = Update-RdpUserProfiles $PublicDesktop
            Write-Host '[4/5] Genero e firmo il collegamento.'
            $stage = Join-Path $script:RunDirectory 'connection.rdp'
            [IO.File]::WriteAllLines($stage, $RdpLines, [Text.Encoding]::Unicode)
            Protect-AndSignRdp $stage
            Write-Host '[5/5] Pubblico il nuovo RDP e pulisco i file con backup verificato.'
            Publish-RdpFile $stage $TargetPath $profiles.Desktops $script:RunDirectory
            if ($profiles.Errors.Count) { throw "RDP pubblico installato, ma $($profiles.Errors.Count) profili non completati. Vedi profile-errors.txt in $script:RunDirectory." }
            $result.Status = 'Deployed'
            if (@($Readiness.Reasons).Count -or @($Readiness.QueryErrors).Count) {
                $result.Status = 'DeployedWithWarnings'
                Write-Warning 'File distribuito; restano vincoli o controlli non verificati indicati nella diagnostica. Il riuso delle credenziali non e garantito.'
            } else { Write-Host 'OK: distribuzione completata per tutti i profili rilevati.' }
            Write-Host 'Operazione completata senza richiedere riavvio del PC o disconnessione degli utenti.'
            Write-Host 'Aprire il NUOVO collegamento in una nuova finestra RDP. Le connessioni gia aperte mantengono la configurazione precedente.'
            Write-Host 'Al primo accesso: nome utente, password e Memorizza credenziali, se consentito dalle policy effettive.'
        } catch {
            $result.Status = 'FailedOrPartial'
            $result.Error = $_.Exception.Message
            throw
        } finally {
            $result.Finished = (Get-Date).ToString('o')
            [pscustomobject]$result | ConvertTo-Json -Depth 4 |
                Set-Content -LiteralPath (Join-Path $script:RunDirectory 'result.json') -Encoding UTF8
        }
    }

    # Entry point unico per file locale, irm | iex e ScriptBlock con argomenti.
    $config = Get-DeployConfig -Arguments @($CliArguments)
    $readOnly = $config.Anteprima -or $config.Verifica
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $decision = Get-LaunchDecision ($identity.User.Value -eq 'S-1-5-18') $isAdmin `
        ([Environment]::Is64BitOperatingSystem) ([Environment]::Is64BitProcess) `
        ([Diagnostics.Process]::GetCurrentProcess().SessionId) $readOnly
    if (-not $readOnly -and ($decision.Elevate -or $decision.Native64)) {
        Invoke-DeploymentRelaunch $MyInvocation.MyCommand.ScriptBlock.ToString() @($CliArguments) $decision
        return
    }
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($os.ProductType -ne 1 -or [version]$os.Version -lt [version]'10.0' -or $build -lt 10240) {
        throw 'Questo script va distribuito sui CLIENT Windows 10/11, non sul server RDP.'
    }
    $windowsName = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if ([string]::IsNullOrWhiteSpace($publicDesktop)) { throw 'Desktop pubblico non trovato.' }
    $targetPath = Join-Path $publicDesktop $config.NomeFile
    $rdpLines = Get-RdpLines $config
    Write-Host "[$env:COMPUTERNAME] $windowsName (build $build) - $($config.Server) - $($config.Dominio)"
    Write-Host "Identita: $($identity.Name); SID: $($identity.User.Value); processo 64 bit: $([Environment]::Is64BitProcess)"
    Write-Host "Destinazione: $targetPath"
    if ($config.Anteprima) {
        Write-Host 'ANTEPRIMA: nessuna modifica. Tutti i .rdp direttamente nei Desktop utente/pubblico saranno rimossi dopo backup.'
        $rdpLines
        return
    }
    $readiness = Get-RdpReadiness -ServerHost $config.ServerHost
    Write-RdpReadiness -Readiness $readiness
    if ($config.Verifica) {
        Write-Host 'VERIFICA: sola lettura. Nessuna modifica a file, registro, certificati o sessioni.'
        return $readiness
    }
    Invoke-RdpDeployment $config $publicDesktop $targetPath $rdpLines $readiness
} -CliArguments $args
