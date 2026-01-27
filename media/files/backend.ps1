# Configuración
$port = 3001

# --- CREDENCIALES DE LAS MÁQUINAS VIRTUALES (NUEVO) ---
# IMPORTANTE: Cambia esto por el usuario y contraseña REAL de tu Windows virtual
# para que se puedan ejecutar comandos dentro (ipconfig, tasklist, etc).
$vm_user = "Pablo1"      
$vm_pass = "prueba"   

$vbox_paths = @(
    "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
    "C:\Program Files (x86)\Oracle\VirtualBox\VBoxManage.exe",
    "$env:VBOX_MSI_INSTALL_PATH\VBoxManage.exe"
)

$vbox_cmd = $null
foreach ($path in $vbox_paths) {
    if (Test-Path $path) { $vbox_cmd = $path; break }
}
if (-not $vbox_cmd) { 
    # Fallback: intentar usar el comando si está en el PATH
    if (Get-Command "VBoxManage" -ErrorAction SilentlyContinue) { $vbox_cmd = "VBoxManage" }
    else { Write-Host "ERROR: No encuentro VirtualBox." -ForegroundColor Red; exit }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:${port}/")
try { $listener.Start() } catch { Write-Host "Error: Puerto ocupado. Cierra la otra ventana de PowerShell." -ForegroundColor Red; exit }

Write-Host "--- [ SYSTEM CONTROL ONLINE v3.0 (REAL OPS) ] ---" -ForegroundColor Cyan
Write-Host "Modo: GUI (Ventanas Visibles) + Guest Control" -ForegroundColor Gray
Write-Host "Credenciales VM: $vm_user / *****" -ForegroundColor DarkGray
Write-Host "Escuchando..." -ForegroundColor Green

# Función auxiliar para ejecutar VBoxManage y capturar errores reales
function Exec-VBox {
    param($ArgsList)
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $vbox_cmd
    $pinfo.Arguments = $ArgsList
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true
    
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $pinfo
    $p.Start() | Out-Null
    $p.WaitForExit()
    
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    
    return @{ out=$stdout; err=$stderr; code=$p.ExitCode }
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    $response.AddHeader("Access-Control-Allow-Origin", "*")
    $response.AddHeader("Access-Control-Allow-Headers", "Content-Type")
    $response.Headers.Add("Content-Type", "application/json")

    if ($request.HttpMethod -eq "OPTIONS") { $response.Close(); continue }

    $output = "{}"

    # --- LISTAR (AHORA CON IP REAL) ---
    if ($request.Url.LocalPath -eq "/api/servers") {
        $runRes = Exec-VBox "list runningvms"
        $allRes = Exec-VBox "list vms"
        
        $servers = @()
        if ($allRes.out) {
            $lines = $allRes.out -split "`r`n"
            foreach ($line in $lines) {
                if ($line -match '"(.*)" \{(.*)\}') {
                    $name = $matches[1]; $id = $matches[2]
                    # Comprobación estricta de estado
                    $isRunning = $runRes.out.Contains($id)
                    
                    # --- NUEVO: OBTENER IP REAL ---
                    $ipReal = "127.0.0.1" # Fallback por si está apagada
                    if ($isRunning) {
                        # Consultamos la propiedad de red de las Guest Additions
                        $netInfo = Exec-VBox "guestproperty get ""$id"" ""/VirtualBox/GuestInfo/Net/0/V4/IP"""
                        if ($netInfo.out -match "Value: (.*)") {
                            $ipReal = $matches[1].Trim()
                        }
                    }
                    
                    $servers += @{
                        id = $id
                        name = $name
                        ip = $ipReal # Aquí inyectamos la IP real
                        status = if ($isRunning) { "running" } else { "stopped" }
                        cpu = if ($isRunning) { Get-Random -Min 10 -Max 90 } else { 0 }
                        ram = if ($isRunning) { Get-Random -Min 20 -Max 80 } else { 0 }
                    }
                }
            }
        }
        $output = $servers | ConvertTo-Json -Depth 3 -Compress
        
    # --- NUEVO: EJECUTAR COMANDOS REALES (/exec) ---
    } elseif ($request.Url.LocalPath -match "/api/server/(.*)/exec") {
        $id = $request.Url.LocalPath.Split('/')[3]
        $reader = New-Object System.IO.StreamReader $request.InputStream
        $body = $reader.ReadToEnd()
        $json = $body | ConvertFrom-Json
        $cmd = $json.command

        Write-Host "CMD EXEC [$id]: $cmd" -ForegroundColor Yellow

        # Usamos guestcontrol para ejecutar dentro de la VM
        # Requiere Guest Additions instaladas en la VM
        $argsExec = "guestcontrol ""$id"" run --exe ""C:\Windows\System32\cmd.exe"" --username ""$vm_user"" --password ""$vm_pass"" --wait-stdout -- /c ""$cmd"""
        
        # Ejecutamos manualmente para controlar mejor el string de argumentos complejos
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $vbox_cmd
        $pinfo.Arguments = $argsExec
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $pinfo
        $p.Start() | Out-Null
        $p.WaitForExit()
        
        $resOut = $p.StandardOutput.ReadToEnd()
        $resErr = $p.StandardError.ReadToEnd()

        if ($p.ExitCode -eq 0) {
             # Limpiamos saltos de línea extraños
             $cleanOut = $resOut -replace "`r", "" 
             $payload = @{ output = $cleanOut }
             $output = $payload | ConvertTo-Json
        } else {
             Write-Host "Error GuestControl: $resErr" -ForegroundColor Red
             $errData = @{ output = "ERROR: No se pudo conectar a la VM.`n1. Revisa usuario/clave en backend.ps1`n2. Instala Guest Additions`n`nLog: $resErr" }
             $output = $errData | ConvertTo-Json
        }

    # --- NUEVO: ESTADÍSTICAS (/stats) ---
    } elseif ($request.Url.LocalPath -match "/api/server/(.*)/stats") {
        # Simulamos estadísticas para el gráfico (VBox metrics es muy lento para una demo fluida)
        $stats = @{ cpu = (Get-Random -Min 5 -Max 60); ram = (Get-Random -Min 30 -Max 80) }
        $output = $stats | ConvertTo-Json

    # --- CONTROL POWER (TU CÓDIGO ORIGINAL) ---
    } elseif ($request.Url.LocalPath -match "/api/server/(.*)/power") {
        $id = $request.Url.LocalPath.Split('/')[3]
        $reader = New-Object System.IO.StreamReader $request.InputStream
        $body = $reader.ReadToEnd()
        $json = $body | ConvertFrom-Json
        $action = $json.action
        
        Write-Host "CMD: [$action] -> $id" -NoNewline

        $res = $null
        switch ($action) {
            # --type gui mantenido
            "start"      { $res = Exec-VBox "startvm ""$id"" --type gui" } 
            "stop"       { $res = Exec-VBox "controlvm ""$id"" acpipowerbutton" }
            "force-stop" { $res = Exec-VBox "controlvm ""$id"" poweroff" }
            "reset"      { $res = Exec-VBox "controlvm ""$id"" reset" }
            "pause"      { $res = Exec-VBox "controlvm ""$id"" pause" }
        }

        if ($res.code -eq 0) {
            Write-Host " [OK]" -ForegroundColor Green
            $output = '{"success": true}'
        } else {
            Write-Host " [ERROR]" -ForegroundColor Red
            Write-Host $res.err -ForegroundColor DarkRed
            $errText = $res.err -replace '"', '\"' -replace "`r`n", " "
            $output = "{`"success`": false, `"error`": `"$errText`"}"
        }
    }

    $buffer = [System.Text.Encoding]::UTF8.GetBytes($output)
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.Close()
}