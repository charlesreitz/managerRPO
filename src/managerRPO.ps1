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
    [string]$RpoType
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
Tenta abrir o arquivo com lock exclusivo (FileShare.None).
Retorna $true se conseguiu (e libera o handle imediatamente), $false se estiver em uso.
#>
function Test-ExclusiveFileLock {
    Param([Parameter(Mandatory=$true)][string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $stream) {
            $stream.Close()
            $stream.Dispose()
        }
    }
}

<#
Valida lock exclusivo em todos os appserver.ini que serão alterados.
Falha cedo (antes de qualquer alteração no .ini) se algum arquivo estiver em uso.
#>
function Assert-AppserverIniExclusiveLock {
    Param(
        [Parameter(Mandatory=$true)][string[]]$IniFilePaths
    )

    $lockedFiles = @()
    foreach ($iniPath in $IniFilePaths) {
        if (-not (Test-Path -LiteralPath $iniPath)) {
            Write-ManagerLog -Level WARN -Message "Arquivo .ini não encontrado na pré-validação de lock: $iniPath"
            continue
        }
        Write-ManagerLog -Level INFO -Message "Testando lock exclusivo: $iniPath"
        if (-not (Test-ExclusiveFileLock -FilePath $iniPath)) {
            Write-ManagerLog -Level WARN -Message "Lock exclusivo negado (arquivo em uso): $iniPath"
            $lockedFiles += $iniPath
        }
        else {
            Write-ManagerLog -Level SUCCESS -Message "Lock exclusivo OK: $iniPath"
        }
    }

    if ($lockedFiles.Count -gt 0) {
        $lista = ($lockedFiles | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw @"
Não foi possível obter lock exclusivo nos arquivos .ini abaixo (arquivo em uso por outro processo, ex.: appserver).
Nenhuma alteração foi iniciada nos .ini para evitar corrupção/arquivo em branco:
$lista
Feche o processo que está usando o(s) arquivo(s) e execute novamente.
"@
    }
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
        [string]$PathProtheusRemoto = ""
    )

    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($appserver in $Appservers) {
        $localIni = "$PathProtheus$PathBinarios\$appserver\$AppserverIniFile"
        if (Test-Path -LiteralPath $localIni) {
            $paths.Add($localIni)
        }
        if ($PathProtheusRemoto) {
            $remoteIni = "$PathProtheusRemoto$PathBinarios\$appserver\$AppserverIniFile"
            if (Test-Path -LiteralPath $remoteIni) {
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
$cGetPath           = Get-Location
$script:logfile     = "$cGetPath\managerRPO.log"

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

Write-ManagerLog -Level INFO -Message "Ambiente principal: $cEnvironment | Appservers: $($aAppservers -join ', ') | Environments: $($aEnvironments -join ', ')"
if (-not $cPathProtheusRemoto) {
    Write-ManagerLog -Level WARN -Message "PathProtheusRemoto não configurado - atualização remota será ignorada."
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

        # Pré-validação: lock exclusivo em TODOS os .ini antes de qualquer alteração
        Write-ManagerLog -Level INFO -Message "Etapa: pré-validação de lock exclusivo nos .ini..."
        $iniPathsToUpdate = Get-AppserverIniPathsToUpdate `
            -Appservers $aAppservers `
            -PathProtheus $cPathProtheus `
            -PathBinarios $cPathBinarios `
            -AppserverIniFile $cAppserverIniFile `
            -PathProtheusRemoto $cPathProtheusRemoto
        if ($iniPathsToUpdate.Count -eq 0) {
            throw "Nenhum arquivo $cAppserverIniFile encontrado para atualização nos appservers configurados."
        }
        Write-ManagerLog -Level INFO -Message "Arquivos .ini candidatos ($($iniPathsToUpdate.Count)): $($iniPathsToUpdate -join ' | ')"
        Assert-AppserverIniExclusiveLock -IniFilePaths $iniPathsToUpdate
        Write-ManagerLog -Level SUCCESS -Message "Pré-validação de lock concluída - seguindo para alteração dos .ini."

        # Atualiza os arquivos .ini dos appservers locais
        Write-ManagerLog -Level INFO -Message "Etapa: atualização dos .ini locais..."
        $keyValueList = @{ $cIniKeyToUpdate = $cIniValueLocal }
        foreach ($appserver in $aAppservers) {
            $cIniFile = "$cPathProtheus$cPathBinarios\$appserver\$cAppserverIniFile"
            if (Test-Path $cIniFile) {
                $cIniFileBak = "$cPathProtheus$cPathBinarios\$appserver\$($cAppserverNameFile)_$cRPONewFolderTimestamp.bak"
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
                Write-ManagerLog -Level WARN -Message "appserver.ini local não encontrado para '$appserver': $cIniFile - pulando."
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
                $cIniFileRemoto = "$cPathProtheusRemoto$cPathBinarios\$appserver\$cAppserverIniFile"
                if (Test-Path $cIniFileRemoto) {
                    $cIniFileBakRemoto = "$cPathProtheusRemoto$cPathBinarios\$appserver\$($cAppserverNameFile)_$cRPONewFolderTimestamp.bak"
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
                    Write-ManagerLog -Level WARN -Message "appserver.ini remoto não encontrado para '$appserver': $cIniFileRemoto - pulando."
                }
            }
        }

        $lReturn = $true
        Write-ManagerLog -Level SUCCESS -Message "Troca de RPO finalizada com sucesso!"
        Write-ManagerLog -Level INFO -Message "========== Fim da troca de RPO (SUCESSO) =========="

    } catch {
        Write-ManagerLog -Level ERROR -Message "Ocorreu um erro: $($_.Exception.Message)"
        Write-ManagerLog -Level INFO -Message "========== Fim da troca de RPO (FALHA) =========="
        Break
    }
    Finally {
        $Time=Get-Date
        $statusMsg = "$Time | User:$env:USERNAME | Tipo:$($RpoType.ToUpper()) | Status:$(if($lReturn){'Sucesso'}else{'Falha'})"
        $statusMsg | Out-File $script:logfile -Append
        Write-ManagerLog -Level INFO -Message "Resumo gravado em log: $statusMsg"
    }
    
    return $lReturn
}

<#
Grava o conteúdo no destino via arquivo temporário + substituição.
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
        # Garante que ninguém está segurando o destino antes da troca
        if (-not (Test-ExclusiveFileLock -FilePath $FilePath)) {
            throw "Arquivo em uso no momento da gravação (sem lock exclusivo): $FilePath"
        }

        [System.IO.File]::WriteAllLines($tempPath, $normalizedLines, $encoding)

        $tempInfo = Get-Item -LiteralPath $tempPath
        if ($tempInfo.Length -le 0) {
            throw "Abortado: arquivo temporário ficou vazio ao gravar: $tempPath"
        }

        # File.Replace com $null no PowerShell vira "" e quebra; usa backup temporário e remove em seguida
        [System.IO.File]::Replace($tempPath, $FilePath, $backupPath)
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
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
Usa lock exclusivo e gravação segura (sem Set-Content in-place) para evitar .ini em branco.
#> 
function Set-OrAddIniValue {
    Param(
        [string]$FilePath,
        [string]$Section,
        [hashtable]$keyValueList
    )

    For ($i=0; $i -le 10; $i++) {
        try {
            if (-not (Test-ExclusiveFileLock -FilePath $FilePath)) {
                throw "Arquivo em uso (sem lock exclusivo): $FilePath"
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

Write-ManagerLog -Level INFO -Message "Invocando ChangeRPOFile..."
$success = ChangeRPOFile
if ($success) {
    Write-ManagerLog -Level SUCCESS -Message "Script finalizado com exit code 0."
    exit 0 # Sucesso
} else {
    Write-ManagerLog -Level ERROR -Message "Script finalizado com exit code 1."
    exit 1 # Falha
}