<#
CHARLES REITZ - 25/06/2018 
charles.reitz@totvs.com.br
Script para automatizar tarefas para o sistema TOTVS Microsiga Protheus, sendo elas:
- Troca de RPO a quente (Default ou Custom) informando um RPO de origem

PS: gentileza não remover as credencias de criação, seja gentil.

##Set-ExecutionPolicy RemoteSigned ##COMANDO PARA HABILITAR A EXECUÇÃO DE SCRIPTS NO SERVIDOR, PRECISA RODAR COM ADMIN
#>

Param(
    [Parameter(Mandatory=$true, HelpMessage="Especifique o tipo de RPO: 'default' ou 'custom'")]
    [ValidateSet('default', 'custom')]
    [string]$RpoType,

    # Uso interno: indica que o script foi relançado com privilégio de administrador (evita loop de elevação)
    [switch]$Elevated,

    # Uso interno: caminho absoluto do log repassado ao processo elevado (que inicia em System32)
    [string]$LogFile
)

$ErrorActionPreference = 'Stop' 

Add-Type -AssemblyName System.Windows.Forms

<#
Log padronizado por etapa.
Levels: INFO (Cyan), SUCCESS (Green), WARN (Yellow), ERROR (Red)
Também grava em managerRPO.log quando $script:logfile estiver definido.
#>
function Write-ManagerLog {
    Param(
        [Parameter(Mandatory=$true)][ValidateSet('INFO','SUCCESS','WARN','ERROR')]
        [string]$Level,
        [Parameter(Mandatory=$true)][string]$Message
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line -ForegroundColor Cyan }
    }

    if ($script:logfile) {
        try {
            $line | Out-File -FilePath $script:logfile -Append -Encoding Default
        }
        catch {
            Write-Host "[$timestamp] [WARN] Falha ao gravar no log em arquivo: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

#Função responsável por pegar as informações do arquivo ini
function Get-IniContent ($filePath)
{
    $ini = @{}
    switch -regex -file $FilePath
    {
        "^\[(.+)\]" # Section
        {
            $section = $matches[1]
            $ini[$section] = @{}
            $CommentCount = 0
        }
        "^(;.*)$" # Comment
        {
            $value = $matches[1]
            $CommentCount = $CommentCount + 1
            $name = "Comment" + $CommentCount
            $ini[$section][$name] = $value
        } 
        "(.+?)\s*=(.*)" # Key
        {
            $name,$value = $matches[1..2]
            $ini[$section][$name] = $value.Trim()
        }
    }
    return $ini
}

<#
Retorna $true se o processo atual está rodando com privilégio de administrador (token elevado).
Com UAC ativo, um usuário do grupo Administradores sem elevação retorna $false.
#>
function Test-IsAdmin {
    $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
Classifica a exceção de acesso a arquivo/pasta:
Denied (sem permissão - elevação pode resolver), Missing, Locked (em uso por outro processo) ou Error.
#>
function Get-AccessErrorStatus {
    Param([Parameter(Mandatory=$true)]$ErrorRecord)

    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($ex -is [System.UnauthorizedAccessException] -or $ex -is [System.Security.SecurityException]) { return 'Denied' }
        if ($ex -is [System.IO.FileNotFoundException] -or $ex -is [System.IO.DirectoryNotFoundException]) { return 'Missing' }
        if ($ex -is [System.IO.IOException]) { return 'Locked' }
        $ex = $ex.InnerException
    }
    return 'Error'
}

<#
Testa acesso a um arquivo (Read ou Write) compartilhando leitura/escrita (FileShare.ReadWrite).
Não exige exclusividade: o appserver em execução mantém o .ini aberto e um lock exclusivo
(FileShare.None) sempre falharia.
Retorna: OK, Missing, ReadOnly, Denied, Locked ou Error (e libera o handle imediatamente).
#>
function Get-FileAccessStatus {
    Param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [ValidateSet('Read','Write')][string]$Access = 'Write'
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return 'Missing'
    }
    if ($Access -eq 'Write' -and (Get-Item -LiteralPath $FilePath -Force).IsReadOnly) {
        return 'ReadOnly'
    }

    $fileAccess = if ($Access -eq 'Write') { [System.IO.FileAccess]::ReadWrite } else { [System.IO.FileAccess]::Read }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $FilePath,
            [System.IO.FileMode]::Open,
            $fileAccess,
            [System.IO.FileShare]::ReadWrite
        )
        return 'OK'
    }
    catch {
        return (Get-AccessErrorStatus -ErrorRecord $_)
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

<#
Atalho booleano: $true se o arquivo pode ser aberto para escrita agora.
#>
function Test-FileWriteAccess {
    Param([Parameter(Mandatory=$true)][string]$FilePath)
    return ((Get-FileAccessStatus -FilePath $FilePath -Access Write) -eq 'OK')
}

<#
Testa se é possível criar arquivo e subpasta dentro da pasta (cópia do RPO via robocopy,
backup .bak e arquivo temporário do .ini). Os itens de teste são removidos em seguida.
Retorna: OK, Missing, Denied, Locked ou Error.
#>
function Get-FolderWriteStatus {
    Param([Parameter(Mandatory=$true)][string]$FolderPath)

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        return 'Missing'
    }

    $probeName = ".managerRPO_perm_$([guid]::NewGuid().ToString('N'))"
    $probeFile = Join-Path $FolderPath "$probeName.tmp"
    $probeDir  = Join-Path $FolderPath $probeName
    $stream = $null
    try {
        # DeleteOnClose: o arquivo de teste some ao liberar o handle
        $stream = New-Object System.IO.FileStream(
            $probeFile,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            1,
            [System.IO.FileOptions]::DeleteOnClose
        )
        $stream.Dispose()
        $stream = $null

        [void][System.IO.Directory]::CreateDirectory($probeDir)
        [System.IO.Directory]::Delete($probeDir)
        return 'OK'
    }
    catch {
        return (Get-AccessErrorStatus -ErrorRecord $_)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $probeDir) {
            Remove-Item -LiteralPath $probeDir -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
Executa todas as checagens de permissão antes de qualquer alteração.
$Checks: lista de @{ Type = 'FileRead' | 'FileWrite' | 'FolderWrite'; Path = '...' }
Retorna @{ Denied = [itens sem permissão]; Problems = [itens com outros problemas (em uso, somente leitura, ...)] }
#>
function Test-RequiredPermissions {
    Param([Parameter(Mandatory=$true)][object[]]$Checks)

    $denied   = New-Object 'System.Collections.Generic.List[string]'
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $seen     = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($check in $Checks) {
        if (-not $seen.Add("$($check.Type)|$($check.Path)")) { continue }

        $status = switch ($check.Type) {
            'FileRead'    { Get-FileAccessStatus -FilePath $check.Path -Access Read }
            'FileWrite'   { Get-FileAccessStatus -FilePath $check.Path -Access Write }
            'FolderWrite' { Get-FolderWriteStatus -FolderPath $check.Path }
        }
        $label = "[$($check.Type)] $($check.Path)"

        switch ($status) {
            'OK'       { Write-ManagerLog -Level SUCCESS -Message "Permissão OK: $label" }
            'Denied'   { Write-ManagerLog -Level WARN -Message "Sem permissão: $label"; $denied.Add($label) }
            'Locked'   { Write-ManagerLog -Level WARN -Message "Em uso por outro processo (sem compartilhar escrita): $label"; $problems.Add("$label (em uso por outro processo)") }
            'ReadOnly' { Write-ManagerLog -Level WARN -Message "Arquivo marcado como somente leitura: $label"; $problems.Add("$label (atributo somente leitura)") }
            'Missing'  { Write-ManagerLog -Level WARN -Message "Não encontrado: $label"; $problems.Add("$label (não encontrado)") }
            default    { Write-ManagerLog -Level WARN -Message "Falha ao testar acesso: $label"; $problems.Add("$label (falha ao testar acesso)") }
        }
    }

    return @{ Denied = $denied.ToArray(); Problems = $problems.ToArray() }
}

<#
Converte caminho em unidade de rede mapeada (ex.: Z:\pasta) para UNC (\\servidor\share\pasta).
Caminhos locais ou já UNC são retornados sem alteração.
#>
function ConvertTo-UncPath {
    Param([string]$Path)

    if ($Path -notmatch '^([A-Za-z]):(.*)$') { return $Path }
    $rest = $Matches[2]
    try {
        $root = (Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction Stop).DisplayRoot
        if ($root -and $root.StartsWith('\\')) {
            return $root.TrimEnd('\') + $rest
        }
    } catch { }
    return $Path
}

<#
Relança este script com privilégio de administrador (UAC) e aguarda o término.
Mantém o diretório de trabalho atual (log) e o -RpoType. Retorna o exit code do processo elevado.
#>
function Invoke-SelfElevated {
    $quote = { Param([string]$s) "'" + ($s -replace "'", "''") + "'" }

    # Unidades de rede mapeadas podem não estar visíveis na sessão elevada (prefira caminho UNC no managerRPO.ini)
    foreach ($p in @($cPathProtheus, $cPathProtheusRemoto)) {
        if ($p -and $p -match '^[A-Za-z]:') {
            try {
                if ((New-Object System.IO.DriveInfo($p.Substring(0, 1))).DriveType -eq 'Network') {
                    Write-ManagerLog -Level WARN -Message "Caminho '$p' usa unidade de rede mapeada - pode não estar acessível como administrador. Prefira caminho UNC (\\servidor\compartilhamento)."
                }
            } catch { }
        }
    }

    # A sessão elevada inicia em System32 e pode não enxergar unidades mapeadas:
    # repassa pasta de trabalho, script e log como caminhos absolutos (UNC quando for unidade de rede)
    $workDir    = ConvertTo-UncPath (Get-Location).ProviderPath
    $scriptFile = ConvertTo-UncPath $PSCommandPath
    $logPath    = ConvertTo-UncPath $script:logfile
    Write-ManagerLog -Level INFO -Message "Execução elevada usará pasta de trabalho '$workDir' e log '$logPath'."

    $command = "try { Set-Location -LiteralPath $(& $quote $workDir) -ErrorAction Stop } catch { }; " +
               "& $(& $quote $scriptFile) -RpoType $(& $quote $RpoType) -Elevated -LogFile $(& $quote $logPath); exit `$LASTEXITCODE"
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    $psExe   = (Get-Process -Id $PID).Path

    Write-ManagerLog -Level INFO -Message "Solicitando permissão de administrador (UAC) para continuar..."
    try {
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" `
            -Verb RunAs -Wait -PassThru
    }
    catch {
        Write-ManagerLog -Level ERROR -Message "Elevação cancelada ou não permitida: $($_.Exception.Message)"
        return 1
    }

    Write-ManagerLog -Level INFO -Message "Execução como administrador finalizada com exit code $($proc.ExitCode) (detalhes acima em managerRPO.log)."
    return $proc.ExitCode
}

<#
Localiza o .ini do appserver dentro da pasta informada.
- Busca desativada: usa o nome fixo ($AppserverIniFile).
- Busca ativada: procura appserver*.ini (cenário em que o appserver.exe foi renomeado e o .ini acompanha o nome).
  Se encontrar 2 ou mais, descarta o appserver.ini; se ainda sobrar mais de um, é ambíguo e o appserver é pulado.
Retorna o caminho completo do .ini ou $null se não encontrado.
#>
function Resolve-AppserverIniFile {
    Param(
        [Parameter(Mandatory=$true)][string]$AppserverPath,
        [Parameter(Mandatory=$true)][string]$AppserverIniFile,
        [bool]$SearchIni = $false
    )

    if (-not $SearchIni) {
        $iniPath = "$AppserverPath\$AppserverIniFile"
        if (Test-Path -LiteralPath $iniPath) { return $iniPath }
        return $null
    }

    if (-not (Test-Path -LiteralPath $AppserverPath)) {
        return $null
    }

    # Filtro do Windows com extensão de 3 caracteres também casa ".ini*" (ex.: .inibak); garante extensão exata
    $candidates = @(Get-ChildItem -LiteralPath $AppserverPath -Filter "appserver*.ini" -File |
        Where-Object { $_.Extension -eq '.ini' })

    if ($candidates.Count -gt 1) {
        Write-ManagerLog -Level INFO -Message "Busca appserver*.ini em '$AppserverPath' encontrou $($candidates.Count) arquivos: $(($candidates | ForEach-Object { $_.Name }) -join ', ') - descartando $AppserverIniFile."
        $candidates = @($candidates | Where-Object { $_.Name -ne $AppserverIniFile })
    }

    if ($candidates.Count -eq 0) {
        return $null
    }
    if ($candidates.Count -gt 1) {
        Write-ManagerLog -Level WARN -Message "Busca appserver*.ini ambígua em '$AppserverPath': $(($candidates | ForEach-Object { $_.Name }) -join ', ') - pulando."
        return $null
    }

    Write-ManagerLog -Level INFO -Message "Busca appserver*.ini em '$AppserverPath' selecionou: $($candidates[0].Name)"
    return $candidates[0].FullName
}

<#
Monta a lista de appserver.ini (local e remoto) que o script pretende alterar.
#>
function Get-AppserverIniPathsToUpdate {
    Param(
        [Parameter(Mandatory=$true)][string[]]$Appservers,
        [Parameter(Mandatory=$true)][string]$PathProtheus,
        [Parameter(Mandatory=$true)][string]$PathBinarios,
        [Parameter(Mandatory=$true)][string]$AppserverIniFile,
        [string]$PathProtheusRemoto = "",
        [bool]$SearchIni = $false
    )

    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($appserver in $Appservers) {
        $localIni = Resolve-AppserverIniFile -AppserverPath "$PathProtheus$PathBinarios\$appserver" -AppserverIniFile $AppserverIniFile -SearchIni $SearchIni
        if ($localIni) {
            $paths.Add($localIni)
        }
        if ($PathProtheusRemoto) {
            $remoteIni = Resolve-AppserverIniFile -AppserverPath "$PathProtheusRemoto$PathBinarios\$appserver" -AppserverIniFile $AppserverIniFile -SearchIni $SearchIni
            if ($remoteIni) {
                $paths.Add($remoteIni)
            }
        }
    }
    return $paths.ToArray()
}


#------------------------------------------------------------------
#CONFIGURACOES DO SCRIPT
#EFETUAR ALTERACAO DAS VARIAVEIS CONFORME NECESSIDAE DO AMBIENTE
#------------------------------------------------------------------
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition      ##Busca o local de onde esta sendo executado o script
$cGetPath           = (Get-Location).ProviderPath
# No processo elevado o log vem por parâmetro, para continuar na pasta de execução original (e não em System32)
$script:logfile     = if ($LogFile) { $LogFile } else { Join-Path $cGetPath "managerRPO.log" }

Write-ManagerLog -Level INFO -Message "Carregando configurações: $scriptPath\managerRPO.ini"
$iniContent = Get-IniContent $scriptPath"\managerRPO.ini"               ##Carrega configuracoes do arquivo ini para atribuir as variaveis

#--- Configurações de Ambiente ---
$cPathProtheus          = $iniContent["ambiente"]["PathProtheus"]
$cPathProtheusRemoto    = $iniContent["ambiente"]["PathProtheusRemoto"]
$cPathRPO               = $iniContent["ambiente"]["PathRPO"]
$cPathAtualizaRPO       = $iniContent["ambiente"]["PathAtualizaRPO"]
$cPathBinarios          = $iniContent["ambiente"]["PathBinarios"]
$cRPOName               = $iniContent["ambiente"]["RPOName"]
$cRPONameCustom         = $iniContent["ambiente"]["RPONameCustom"]
$aAppservers            = $iniContent["ambiente"]["Appservers"].Split(',')
$aEnvironments          = $iniContent["ambiente"]["Environment"].Split(',')
$cEnvironment           = ($aEnvironments[0]).Trim()
$cPathRPODefault        = $iniContent["ambiente"]["PathRPODefault"]
$cPathRPOCustom         = $iniContent["ambiente"]["PathRPOCustom"]
$lBuscaAppserverIni     = ($iniContent["ambiente"]["BuscaAppserverIni"] -eq "1")

Write-ManagerLog -Level INFO -Message "Ambiente principal: $cEnvironment | Appservers: $($aAppservers -join ', ') | Environments: $($aEnvironments -join ', ')"
if (-not $cPathProtheusRemoto) {
    Write-ManagerLog -Level WARN -Message "PathProtheusRemoto não configurado - atualização remota será ignorada."
}
if ($lBuscaAppserverIni) {
    Write-ManagerLog -Level INFO -Message "BuscaAppserverIni ativo - o .ini de cada appserver será localizado por appserver*.ini."
}

#------------------------------------------------------------------
#Variáveis raramente alteradas 
$cAppserverNameFile = "appserver"
$cAppserverIniFile  = $cAppserverNameFile+".ini"
$logfile            = $script:logfile

#------------------------------------------------------------------

<#
Função responsável por trocar o RPO (default ou custom), copiando de uma pasta de origem para uma de destino
e atualizando os arquivos de configuração dos appservers.
#>
function ChangeRPOFile {
    Write-ManagerLog -Level INFO -Message "========== Início da troca de RPO =========="
    Write-ManagerLog -Level INFO -Message "Tipo de RPO solicitado: $($RpoType.ToUpper())"
    
    $lReturn = $false
    
    # Define variáveis com base no tipo de RPO (Default ou Custom)
    $cTargetSubFolder = ""
    $cIniKeyToUpdate = ""
    $effectiveRpoName = $cRPOName # Default
    
    if ($RpoType -eq 'custom') {
        $cTargetSubFolder = $cPathRPOCustom
        $cIniKeyToUpdate = "RPOCustom"
        if (-not [string]::IsNullOrEmpty($cRPONameCustom)) {
            $effectiveRpoName = $cRPONameCustom
        }
        Write-ManagerLog -Level INFO -Message "Modo CUSTOM | chave INI=$cIniKeyToUpdate | arquivo=$effectiveRpoName | subpasta=$cTargetSubFolder"
    }
    else { # default
        $cTargetSubFolder = $cPathRPODefault
        $cIniKeyToUpdate = "SourcePath"
        Write-ManagerLog -Level INFO -Message "Modo DEFAULT | chave INI=$cIniKeyToUpdate | arquivo=$effectiveRpoName | subpasta=$cTargetSubFolder"
    }

    # Define caminhos de origem e destino
    $cRPOOrigtPath  = $cPathProtheus+$cPathRPO+$cPathAtualizaRPO
    $cRPOOrigFile   = $cRPOOrigtPath+"\"+$effectiveRpoName
    $cRPODestPath   = $cPathProtheus+$cPathRPO+"\"+$cEnvironment+"\"+$cTargetSubFolder
    $cRPODestPathRemoto = $cPathProtheusRemoto+$cPathRPO+"\"+$cEnvironment+"\"+$cTargetSubFolder

    try {
        Write-ManagerLog -Level INFO -Message "Validando caminhos de origem/destino..."
        Write-ManagerLog -Level INFO -Message "Origem RPO: $cRPOOrigFile"
        Write-ManagerLog -Level INFO -Message "Destino local: $cRPODestPath"
        if ($cPathProtheusRemoto) {
            Write-ManagerLog -Level INFO -Message "Destino remoto: $cRPODestPathRemoto"
        }

        # Validações dos caminhos de origem e destino
        if (-not (Test-Path $cRPOOrigFile)) {
            throw "Arquivo de origem não localizado: $cRPOOrigFile" 
        }
        Write-ManagerLog -Level SUCCESS -Message "Arquivo de origem localizado."
        if (-not (Test-Path $cRPODestPath)) {
            throw "Pasta de destino não localizada: $cRPODestPath" 
        }
        Write-ManagerLog -Level SUCCESS -Message "Pasta de destino local OK."
        if (($cPathProtheusRemoto) -and (-not (Test-Path $cRPODestPathRemoto))) {
            throw "Pasta remota configurada não localizada: $cRPODestPathRemoto" 
        }
        if ($cPathProtheusRemoto) {
            Write-ManagerLog -Level SUCCESS -Message "Pasta de destino remoto OK."
        }

        # Pré-validação: permissões em TODAS as pastas e arquivos antes de qualquer alteração
        Write-ManagerLog -Level INFO -Message "Etapa: pré-validação de permissões em pastas e arquivos..."
        $iniPathsToUpdate = Get-AppserverIniPathsToUpdate `
            -Appservers $aAppservers `
            -PathProtheus $cPathProtheus `
            -PathBinarios $cPathBinarios `
            -AppserverIniFile $cAppserverIniFile `
            -PathProtheusRemoto $cPathProtheusRemoto `
            -SearchIni $lBuscaAppserverIni
        if ($iniPathsToUpdate.Count -eq 0) {
            throw "Nenhum arquivo $cAppserverIniFile encontrado para atualização nos appservers configurados."
        }
        Write-ManagerLog -Level INFO -Message "Arquivos .ini candidatos ($($iniPathsToUpdate.Count)): $($iniPathsToUpdate -join ' | ')"

        $permChecks = New-Object 'System.Collections.Generic.List[object]'
        $permChecks.Add(@{ Type = 'FileRead';    Path = $cRPOOrigFile })
        $permChecks.Add(@{ Type = 'FolderWrite'; Path = $cRPODestPath })
        if ($cPathProtheusRemoto) {
            $permChecks.Add(@{ Type = 'FolderWrite'; Path = $cRPODestPathRemoto })
        }
        foreach ($iniPath in $iniPathsToUpdate) {
            # Pasta do appserver: backup .bak e arquivo temporário da gravação do .ini
            $permChecks.Add(@{ Type = 'FolderWrite'; Path = (Split-Path -Parent $iniPath) })
            $permChecks.Add(@{ Type = 'FileWrite';   Path = $iniPath })
        }

        $perm = Test-RequiredPermissions -Checks $permChecks.ToArray()
        if ($perm.Denied.Count -gt 0) {
            $lista = ($perm.Denied | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
            if (-not (Test-IsAdmin)) {
                Write-ManagerLog -Level WARN -Message "Sem permissão em $($perm.Denied.Count) item(ns) - nenhuma alteração foi feita. Será solicitada execução como administrador."
                $script:ElevationRequired = $true
                return $false
            }
            throw @"
Sem permissão nos itens abaixo, mesmo executando como administrador. Nenhuma alteração foi feita:
$lista
Verifique as permissões (NTFS/compartilhamento) e execute novamente.
"@
        }
        if ($perm.Problems.Count -gt 0) {
            $lista = ($perm.Problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
            throw @"
Não foi possível validar o acesso aos itens abaixo. Nenhuma alteração foi feita para evitar corrupção/arquivo em branco:
$lista
Corrija o(s) item(ns) (feche o processo que está usando, remova o atributo somente leitura, etc.) e execute novamente.
"@
        }
        Write-ManagerLog -Level SUCCESS -Message "Pré-validação de permissões concluída - seguindo para as alterações."

        # Cria a nova pasta de backup com timestamp
        $cRPONewFolderTimestamp = (Get-Date).ToString("yyyyMMddHHmmss")
        $cNewBackupFolderLocal = $cRPODestPath + "\" + $cRPONewFolderTimestamp
        
        # Copia os arquivos para o servidor local
        Write-ManagerLog -Level INFO -Message "Etapa: cópia local do RPO | de='$cRPOOrigtPath' para='$cNewBackupFolderLocal'"
        $cmdArgs = @("$cRPOOrigtPath", "$cNewBackupFolderLocal", "$effectiveRpoName", "/R:1", "/W:1", "/S")  
        robocopy @cmdArgs | Out-Null
        
        $cCopiedRpoFileLocal = $cNewBackupFolderLocal + "\" + $effectiveRpoName
        if (-not (Test-Path $cCopiedRpoFileLocal)) {
            throw "Falha ao copiar RPO para o destino local: $cCopiedRpoFileLocal" 
        }
        Write-ManagerLog -Level SUCCESS -Message "Cópia local do RPO concluída: $cCopiedRpoFileLocal"

        # Define o valor a ser atualizado no INI
        $cIniValueLocal = if ($RpoType -eq 'custom') { $cCopiedRpoFileLocal } else { $cNewBackupFolderLocal }
        Write-ManagerLog -Level INFO -Message "Valor INI local ($cIniKeyToUpdate)=$cIniValueLocal"

        # Atualiza os arquivos .ini dos appservers locais
        Write-ManagerLog -Level INFO -Message "Etapa: atualização dos .ini locais..."
        $keyValueList = @{ $cIniKeyToUpdate = $cIniValueLocal }
        foreach ($appserver in $aAppservers) {
            $cAppserverPath = "$cPathProtheus$cPathBinarios\$appserver"
            $cIniFile = Resolve-AppserverIniFile -AppserverPath $cAppserverPath -AppserverIniFile $cAppserverIniFile -SearchIni $lBuscaAppserverIni
            if ($cIniFile) {
                $cIniFileBak = "$cAppserverPath\$([System.IO.Path]::GetFileNameWithoutExtension($cIniFile))_$cRPONewFolderTimestamp.bak"
                Write-ManagerLog -Level INFO -Message "Appserver local '$appserver' | INI=$cIniFile"
                Write-ManagerLog -Level INFO -Message "Gerando backup: $cIniFileBak"
                Copy-Item $cIniFile $cIniFileBak -Force
                if (-not (Test-Path $cIniFileBak)) { throw "Falha ao gerar backup do .INI local: $cIniFileBak" }
                Write-ManagerLog -Level SUCCESS -Message "Backup local gerado."
                
                foreach ($env in $aEnvironments) {
                    $trimmedEnv = $env.Trim()
                    Write-ManagerLog -Level INFO -Message "Atualizando seção [$trimmedEnv] em $cIniFile"
                    Set-OrAddIniValue -FilePath $cIniFile -Section $trimmedEnv -keyValueList $keyValueList
                }
            }
            else {
                Write-ManagerLog -Level WARN -Message "appserver.ini local não encontrado para '$appserver' em $cAppserverPath - pulando."
            }
        }

        # Se um caminho remoto estiver configurado, repete o processo para o servidor remoto
        if ($cPathProtheusRemoto) {
            $cNewBackupFolderRemoto = $cRPODestPathRemoto + "\" + $cRPONewFolderTimestamp
            Write-ManagerLog -Level INFO -Message "Etapa: cópia remota do RPO | de='$cRPOOrigtPath' para='$cNewBackupFolderRemoto'"
            $cmdArgsRemoto = @("$cRPOOrigtPath", "$cNewBackupFolderRemoto", "$effectiveRpoName", "/R:1", "/W:1", "/S")  
            robocopy @cmdArgsRemoto | Out-Null

            $cCopiedRpoFileRemoto = $cNewBackupFolderRemoto + "\" + $effectiveRpoName
            if (-not (Test-Path $cCopiedRpoFileRemoto)) {
                throw "Falha ao copiar RPO para o destino remoto: $cCopiedRpoFileRemoto" 
            }
            Write-ManagerLog -Level SUCCESS -Message "Cópia remota do RPO concluída: $cCopiedRpoFileRemoto"
            
            $cIniValueRemoto = if ($RpoType -eq 'custom') { $cCopiedRpoFileRemoto } else { $cNewBackupFolderRemoto }
            Write-ManagerLog -Level INFO -Message "Valor INI remoto ($cIniKeyToUpdate)=$cIniValueRemoto"

            Write-ManagerLog -Level INFO -Message "Etapa: atualização dos .ini remotos..."
            $keyValueListRemoto = @{ $cIniKeyToUpdate = $cIniValueRemoto }
            foreach ($appserver in $aAppservers) {
                $cAppserverPathRemoto = "$cPathProtheusRemoto$cPathBinarios\$appserver"
                $cIniFileRemoto = Resolve-AppserverIniFile -AppserverPath $cAppserverPathRemoto -AppserverIniFile $cAppserverIniFile -SearchIni $lBuscaAppserverIni
                if ($cIniFileRemoto) {
                    $cIniFileBakRemoto = "$cAppserverPathRemoto\$([System.IO.Path]::GetFileNameWithoutExtension($cIniFileRemoto))_$cRPONewFolderTimestamp.bak"
                    Write-ManagerLog -Level INFO -Message "Appserver remoto '$appserver' | INI=$cIniFileRemoto"
                    Write-ManagerLog -Level INFO -Message "Gerando backup remoto: $cIniFileBakRemoto"
                    Copy-Item $cIniFileRemoto $cIniFileBakRemoto -Force
                    if (-not (Test-Path $cIniFileBakRemoto)) { throw "Falha ao gerar backup do .INI remoto: $cIniFileBakRemoto" }
                    Write-ManagerLog -Level SUCCESS -Message "Backup remoto gerado."
                    
                    foreach ($env in $aEnvironments) {
                        $trimmedEnv = $env.Trim()
                        Write-ManagerLog -Level INFO -Message "Atualizando seção [$trimmedEnv] em $cIniFileRemoto"
                        Set-OrAddIniValue -FilePath $cIniFileRemoto -Section $trimmedEnv -keyValueList $keyValueListRemoto
                    }
                }
                else {
                    Write-ManagerLog -Level WARN -Message "appserver.ini remoto não encontrado para '$appserver' em $cAppserverPathRemoto - pulando."
                }
            }
        }

        $lReturn = $true
        Write-ManagerLog -Level SUCCESS -Message "Troca de RPO finalizada com sucesso!"
        Write-ManagerLog -Level INFO -Message "========== Fim da troca de RPO (SUCESSO) =========="

    } catch {
        Write-ManagerLog -Level ERROR -Message "Ocorreu um erro: $($_.Exception.Message)"
        Write-ManagerLog -Level INFO -Message "========== Fim da troca de RPO (FALHA) =========="
    }
    Finally {
        $Time=Get-Date
        $status = if ($lReturn) { 'Sucesso' } elseif ($script:ElevationRequired) { 'Elevação solicitada' } else { 'Falha' }
        $statusMsg = "$Time | User:$env:USERNAME | Admin:$(Test-IsAdmin) | Tipo:$($RpoType.ToUpper()) | Status:$status"
        $statusMsg | Out-File $script:logfile -Append -Encoding Default
        Write-ManagerLog -Level INFO -Message "Resumo gravado em log: $statusMsg"
    }
    
    return $lReturn
}

<#
Grava os bytes no próprio arquivo, compartilhando leitura/escrita com o appserver que o mantém aberto.
Não trunca antes de gravar: sobrescreve a partir do início e só depois ajusta o tamanho (SetLength),
evitando a janela de arquivo em branco do Set-Content. Ao final relê e confere o conteúdo;
se falhar ou divergir, regrava o conteúdo original.
#>
function Write-FileBytesInPlace {
    Param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][byte[]]$Bytes
    )

    $originalBytes = [System.IO.File]::ReadAllBytes($FilePath)
    if ($originalBytes.Length -le 0) {
        throw "Abortado: arquivo original lido vazio antes da gravação in-place: $FilePath"
    }

    $writeBytes = {
        Param([byte[]]$Data)
        $stream = [System.IO.File]::Open(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $stream.Position = 0
            $stream.Write($Data, 0, $Data.Length)
            $stream.SetLength($Data.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
    }

    try {
        & $writeBytes $Bytes
        $checkBytes = [System.IO.File]::ReadAllBytes($FilePath)
        if ([System.Convert]::ToBase64String($checkBytes) -ne [System.Convert]::ToBase64String($Bytes)) {
            throw "Conteúdo gravado diverge do esperado: $FilePath"
        }
    }
    catch {
        $writeError = $_.Exception.Message
        Write-ManagerLog -Level WARN -Message "Falha na gravação in-place ($writeError) - restaurando conteúdo original: $FilePath"
        try {
            & $writeBytes $originalBytes
        }
        catch {
            throw "Falha na gravação in-place e na restauração do conteúdo original. Restaure o .bak manualmente: $FilePath | $writeError | $($_.Exception.Message)"
        }
        throw "Falha na gravação in-place (conteúdo original restaurado): $FilePath | $writeError"
    }
}

<#
Grava o conteúdo no destino via arquivo temporário + substituição atômica (File.Replace).
Se a troca atômica não for possível porque o appserver mantém o .ini aberto (sem compartilhar exclusão),
faz fallback para gravação in-place segura (Write-FileBytesInPlace).
Evita Set-Content in-place, que trunca o arquivo antes de gravar e pode deixá-lo em branco.
Importante: NÃO usar parâmetro nomeado "Content" com List[string] — o binder do PowerShell
falha com linhas em branco do .ini ("Cannot bind ... empty string").
#>
function Write-IniContentSafe {
    Param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    if ($null -eq $Lines -or @($Lines).Count -eq 0) {
        throw "Abortado: conteúdo a gravar está vazio. Arquivo original preservado: $FilePath"
    }

    # Normaliza nulls (Get-Content / List podem gerar) para string vazia = linha em branco válida no .ini
    $normalizedLines = foreach ($line in @($Lines)) {
        if ($null -eq $line) { '' } else { [string]$line }
    }
    $normalizedLines = @($normalizedLines)

    if ($normalizedLines.Count -eq 0) {
        throw "Abortado: conteúdo a gravar está vazio. Arquivo original preservado: $FilePath"
    }

    $tempPath = "$FilePath.tmp.$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$FilePath.bakreplace.$([guid]::NewGuid().ToString('N'))"
    $encoding = [System.Text.Encoding]::Default

    try {
        # Garante que a escrita no destino não está bloqueada antes da troca
        if (-not (Test-FileWriteAccess -FilePath $FilePath)) {
            throw "Arquivo com escrita bloqueada no momento da gravação: $FilePath"
        }

        [System.IO.File]::WriteAllLines($tempPath, $normalizedLines, $encoding)

        $tempInfo = Get-Item -LiteralPath $tempPath
        if ($tempInfo.Length -le 0) {
            throw "Abortado: arquivo temporário ficou vazio ao gravar: $tempPath"
        }

        try {
            # File.Replace com $null no PowerShell vira "" e quebra; usa backup temporário e remove em seguida
            [System.IO.File]::Replace($tempPath, $FilePath, $backupPath)
        }
        catch {
            Write-ManagerLog -Level WARN -Message "Troca atômica indisponível (arquivo aberto por outro processo) - usando gravação in-place: $($_.Exception.Message)"
            # ReplaceFile pode falhar após renomear o original para o backup; devolve o original antes de seguir
            if (-not (Test-Path -LiteralPath $FilePath) -and (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $FilePath -Force
            }
            if (-not (Test-Path -LiteralPath $FilePath)) {
                throw "Arquivo original ausente após falha na troca atômica. Restaure o .bak manualmente: $FilePath"
            }
            Write-FileBytesInPlace -FilePath $FilePath -Bytes ([System.IO.File]::ReadAllBytes($tempPath))
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
Função responsável por localizar e setar os valores no ini, dentro de uma seção específica.
Só altera se a seção (ambiente) já existir no arquivo; caso contrário, ignora sem criar seção.
Valida acesso de escrita e usa gravação segura (sem Set-Content in-place) para evitar .ini em branco.
#> 
function Set-OrAddIniValue {
    Param(
        [string]$FilePath,
        [string]$Section,
        [hashtable]$keyValueList
    )

    For ($i=0; $i -le 10; $i++) {
        try {
            if (-not (Test-FileWriteAccess -FilePath $FilePath)) {
                throw "Arquivo com escrita bloqueada: $FilePath"
            }

            $fileInfo = Get-Item -LiteralPath $FilePath
            if ($fileInfo.Length -le 0) {
                throw "Arquivo .ini está vazio (possível corrupção prévia). Restaure o .bak antes de continuar: $FilePath"
            }

            $content = Get-Content -LiteralPath $FilePath -ErrorAction Stop
            
            # Leitura vazia com arquivo não vazio = falha de I/O / lock
            if ($null -eq $content -or (@($content).Count -eq 0)) {
                throw "Falha ao ler o conteúdo do arquivo (retornou vazio): $FilePath"
            }

            $newContent = New-Object 'System.Collections.Generic.List[string]'
            foreach ($line in @($content)) {
                if ($null -eq $line) { [void]$newContent.Add('') } else { [void]$newContent.Add([string]$line) }
            }

            $sectionLineIndex = -1
            for ($j = 0; $j -lt $newContent.Count; $j++) {
                if ($newContent[$j].Trim() -eq "[$Section]") {
                    $sectionLineIndex = $j
                    break
                }
            }

            if ($sectionLineIndex -eq -1) {
                Write-ManagerLog -Level WARN -Message "Seção [$Section] não existe em $FilePath - atualização ignorada."
                return
            }

            # Find the end of the section
            $endOfSectionIndex = $newContent.Count
            for ($j = $sectionLineIndex + 1; $j -lt $newContent.Count; $j++) {
                $lineText = $newContent[$j]
                if (-not [string]::IsNullOrEmpty($lineText) -and $lineText.Trim().StartsWith("[")) {
                    $endOfSectionIndex = $j
                    break
                }
            }

            foreach ($entry in $keyValueList.GetEnumerator()) {
                $key = $entry.Key
                $value = $entry.Value
                $keyFound = $false
                # Search for the key within the section
                for ($j = $sectionLineIndex + 1; $j -lt $endOfSectionIndex; $j++) {
                    if ($newContent[$j].Trim() -match "^\s*$key\s*=") {
                        # Preserve indentation if present
                        $indent = $newContent[$j] -replace '(\s*).*', '$1'
                        $newContent[$j] = "$indent$key=$value"
                        $keyFound = $true
                        Write-ManagerLog -Level INFO -Message "Chave '$key' atualizada na seção [$Section]."
                        break
                    }
                }

                if (-not $keyFound) {
                    # Key not found, insert it at the end of the section contents
                    $newContent.Insert($endOfSectionIndex, "$key=$value")
                    $endOfSectionIndex++
                    Write-ManagerLog -Level WARN -Message "Chave '$key' não existia na seção [$Section] - incluída ao final da seção."
                }
            }

            Write-ManagerLog -Level INFO -Message "Gravando .ini com troca atômica: $FilePath"
            # ToArray() explícito evita erro do binder com linhas em branco no parâmetro -Content
            Write-IniContentSafe -FilePath $FilePath -Lines ([string[]]$newContent.ToArray())
            Write-ManagerLog -Level SUCCESS -Message "Seção [$Section] gravada com sucesso em $FilePath"
            return
        }
        catch {
             Write-ManagerLog -Level WARN -Message "Tentativa $($i+1)/11 ao acessar $FilePath - $($_.Exception.Message)"
             Start-Sleep -s 2
        }
    }
    throw "ERRO: Não foi possível acessar ou modificar o arquivo $FilePath após 11 tentativas. O arquivo pode estar em uso. Nenhuma gravação insegura foi aplicada neste ciclo."
}

# --- Ponto de Entrada do Script ---

function Exit-Script {
    Param([int]$Code)
    # Na janela elevada (aberta pelo UAC), aguarda o usuário para não fechar sem mostrar o resultado
    if ($Elevated) {
        Read-Host "Pressione Enter para fechar esta janela" | Out-Null
    }
    exit $Code
}

$script:ElevationRequired = $false
Write-ManagerLog -Level INFO -Message "Invocando ChangeRPOFile... (administrador: $(Test-IsAdmin))"
$success = ChangeRPOFile

if ($script:ElevationRequired) {
    $elevatedExitCode = Invoke-SelfElevated
    exit $elevatedExitCode
}

if ($success) {
    Write-ManagerLog -Level SUCCESS -Message "Script finalizado com exit code 0."
    Exit-Script 0 # Sucesso
} else {
    Write-ManagerLog -Level ERROR -Message "Script finalizado com exit code 1."
    Exit-Script 1 # Falha
}