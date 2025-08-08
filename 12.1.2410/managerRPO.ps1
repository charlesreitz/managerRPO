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

Add-Type -AssemblyName System.Windows.Forms

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


#------------------------------------------------------------------
#CONFIGURACOES DO SCRIPT
#EFETUAR ALTERACAO DAS VARIAVEIS CONFORME NECESSIDAE DO AMBIENTE
#------------------------------------------------------------------
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition      ##Busca o local de onde esta sendo executado o script
$iniContent = Get-IniContent $scriptPath"\managerRPO.ini"               ##Carrega configuracoes do arquivo ini para atribuir as variaveis

#--- Configurações de Ambiente ---
$cPathProtheus          = $iniContent["ambiente"]["PathProtheus"]
$cPathProtheusRemoto    = $iniContent["ambiente"]["PathProtheusRemoto"]
$cPathRPO               = $iniContent["ambiente"]["PathRPO"]
$cPathAtualizaRPO       = $iniContent["ambiente"]["PathAtualizaRPO"]
$cPathBinarios          = $iniContent["ambiente"]["PathBinarios"]
$cRPOName               = $iniContent["ambiente"]["RPOName"]
$aAppservers            = $iniContent["ambiente"]["Appservers"].Split(',')
$cEnvironment           = $iniContent["ambiente"]["Environment"]
$cPathRPODefault        = $iniContent["ambiente"]["PathRPODefault"]
$cPathRPOCustom         = $iniContent["ambiente"]["PathRPOCustom"]


#------------------------------------------------------------------
#Variáveis raramente alteradas 
$cAppserverNameFile = "appserver"
$cAppserverIniFile  = $cAppserverNameFile+".ini"
$cGetPath           = Get-Location
$logfile            = "$cGetPath\managerRPO.log"

#------------------------------------------------------------------

<#
Função responsável por trocar o RPO (default ou custom), copiando de uma pasta de origem para uma de destino
e atualizando os arquivos de configuração dos appservers.
#>
function ChangeRPOFile {
    cls
    Write-Host "Iniciando a troca do RPO do tipo: $($RpoType.ToUpper())" -ForegroundColor Green
    
    $lReturn = $false
    
    # Define variáveis com base no tipo de RPO (Default ou Custom)
    $cTargetSubFolder = ""
    $cIniKeyToUpdate = ""
    
    if ($RpoType -eq 'custom') {
        $cTargetSubFolder = $cPathRPOCustom
        $cIniKeyToUpdate = "RPOCustom"
    }
    else { # default
        $cTargetSubFolder = $cPathRPODefault
        $cIniKeyToUpdate = "SourcePath"
    }

    # Define caminhos de origem e destino
    $cRPOOrigtPath  = $cPathProtheus+$cPathRPO+$cPathAtualizaRPO
    $cRPOOrigFile   = $cRPOOrigtPath+"\"+$cRPOName
    $cRPODestPath   = $cPathProtheus+$cPathRPO+"\"+$cEnvironment+"\"+$cTargetSubFolder
    $cRPODestPathRemoto = $cPathProtheusRemoto+$cPathRPO+"\"+$cEnvironment+"\"+$cTargetSubFolder

    try {
        # Validações dos caminhos de origem e destino
        if (-not (Test-Path $cRPOOrigFile)) {
            throw "Arquivo de origem não localizado: $cRPOOrigFile" 
        }
        if (-not (Test-Path $cRPODestPath)) {
            throw "Pasta de destino não localizada: $cRPODestPath" 
        }
        if (($cPathProtheusRemoto) -and (-not (Test-Path $cRPODestPathRemoto))) {
            throw "Pasta remota configurada não localizada: $cRPODestPathRemoto" 
        }

        # Cria a nova pasta de backup com timestamp
        $cRPONewFolderTimestamp = (Get-Date).ToString("yyyyMMddHHmmss")
        $cNewBackupFolderLocal = $cRPODestPath + "\" + $cRPONewFolderTimestamp
        
        # Copia os arquivos para o servidor local
        Write-Host "Copiando RPO de '$cRPOOrigtPath' para '$cNewBackupFolderLocal'"
        $cmdArgs = @("$cRPOOrigtPath", "$cNewBackupFolderLocal", "$cRPOName", "/R:1", "/W:1", "/S")  
        robocopy @cmdArgs | Out-Null
        
        $cCopiedRpoFileLocal = $cNewBackupFolderLocal + "\" + $cRPOName
        if (-not (Test-Path $cCopiedRpoFileLocal)) {
            throw "Falha ao copiar RPO para o destino local: $cCopiedRpoFileLocal" 
        }

        # Define o valor a ser atualizado no INI
        $cIniValueLocal = if ($RpoType -eq 'custom') { $cCopiedRpoFileLocal } else { $cNewBackupFolderLocal }

        # Atualiza os arquivos .ini dos appservers locais
        foreach ($appserver in $aAppservers) {
            $cIniFile = "$cPathProtheus$cPathBinarios\$appserver\$cAppserverIniFile"
            if (Test-Path $cIniFile) {
                $cIniFileBak = "$cPathProtheus$cPathBinarios\$appserver\$($cAppserverNameFile)_$cRPONewFolderTimestamp.bak"
                Write-Host "Atualizando arquivo local: $cIniFile"
                Copy-Item $cIniFile $cIniFileBak -Force
                if (-not (Test-Path $cIniFileBak)) { throw "Falha ao gerar backup do .INI local: $cIniFileBak" }
                
                $keyValueList = @{ $cIniKeyToUpdate = $cIniValueLocal }
                Set-OrAddIniValue -FilePath $cIniFile -keyValueList $keyValueList
            }
        }

        # Se um caminho remoto estiver configurado, repete o processo para o servidor remoto
        if ($cPathProtheusRemoto) {
            $cNewBackupFolderRemoto = $cRPODestPathRemoto + "\" + $cRPONewFolderTimestamp
            Write-Host "Copiando RPO de '$cRPOOrigtPath' para o servidor remoto '$cNewBackupFolderRemoto'"
            $cmdArgsRemoto = @("$cRPOOrigtPath", "$cNewBackupFolderRemoto", "$cRPOName", "/R:1", "/W:1", "/S")  
            robocopy @cmdArgsRemoto | Out-Null

            $cCopiedRpoFileRemoto = $cNewBackupFolderRemoto + "\" + $cRPOName
            if (-not (Test-Path $cCopiedRpoFileRemoto)) {
                throw "Falha ao copiar RPO para o destino remoto: $cCopiedRpoFileRemoto" 
            }
            
            $cIniValueRemoto = if ($RpoType -eq 'custom') { $cCopiedRpoFileRemoto } else { $cNewBackupFolderRemoto }

            foreach ($appserver in $aAppservers) {
                $cIniFileRemoto = "$cPathProtheusRemoto$cPathBinarios\$appserver\$cAppserverIniFile"
                if (Test-Path $cIniFileRemoto) {
                    $cIniFileBakRemoto = "$cPathProtheusRemoto$cPathBinarios\$appserver\$($cAppserverNameFile)_$cRPONewFolderTimestamp.bak"
                    Write-Host "Atualizando arquivo remoto: $cIniFileRemoto"
                    Copy-Item $cIniFileRemoto $cIniFileBakRemoto -Force
                    if (-not (Test-Path $cIniFileBakRemoto)) { throw "Falha ao gerar backup do .INI remoto: $cIniFileBakRemoto" }
                    
                    $keyValueListRemoto = @{ $cIniKeyToUpdate = $cIniValueRemoto }
                    Set-OrAddIniValue -FilePath $cIniFileRemoto -keyValueList $keyValueListRemoto
                }
            }
        }

        $lReturn = $true
        Write-Host "Troca de RPO finalizada com sucesso!" -ForegroundColor Green

    } catch {
        Write-Error "Ocorreu um erro: $($_.Exception.Message)"
        Break
    }
    Finally {
        $Time=Get-Date
        "$Time | User:$env:USERNAME | Tipo:$($RpoType.ToUpper()) | Status:$(if($lReturn){'Sucesso'}else{'Falha'})" | Out-File $logfile -Append
    }
    
    return $lReturn
}

<#
Função responsável por localizar e setar os valores no ini
#> 
function Set-OrAddIniValue {
    Param(
        [string]$FilePath,
        [hashtable]$keyValueList
    )

    For ($i=0; $i -le 10; $i++) {
        try {
            $content = Get-Content $FilePath -ErrorAction Stop
        
            $keyValueList.GetEnumerator() | ForEach-Object {
                if ($content -match "^$($_.Key)=") {
                    $content = $content -replace "^$($_.Key)=(.*)", "$($_.Key)=$($_.Value)"
                }
                else {
                    $content += "$($_.Key)=$($_.Value)"
                }
            }

            $content | Set-Content $FilePath -Force
            return
        }
        catch {
             Write-Host "Tentando acessar o arquivo $FilePath - Tentativa $i"
             Start-Sleep -s 2
        }
    }
    throw "Não foi possível acessar ou modificar o arquivo $FilePath após 10 tentativas."
}

# --- Ponto de Entrada do Script ---
ChangeRPOFile
