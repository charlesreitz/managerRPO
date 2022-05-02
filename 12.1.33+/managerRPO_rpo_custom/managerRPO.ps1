<#
CHARLES REITZ - 25/06/2018 
charles.reitz@totvs.com.br
Script para automatizar tarefaz para o sistema TOTVS Microsiga Protheus, sendo elas:
- Troca de RPO a quente informando um RPO de origem
- AplicaÃ§Ã£o de vÃ¡rios paths buscando de uma determinada pasta

PS: gentileza nÃ£o remover as credencias de criaÃ§Ã£o, seja gentil.

##Set-ExecutionPolicy RemoteSigned ##COMANDO PARA HABILITAR A EXECUÃ‡ÃƒO DE SCRIPTS NO SERVIDOR, PRECISA RODAR COM ADMIN
#>
Add-Type -AssemblyName System.Windows.Forms

#FunÃ§Ã£o resposnavel por pegar as informaÃ§Ãµes do arquivo ini
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
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition     ##Busca o local de onde esta sendo executaod o script
$iniContent = Get-IniContent $scriptPath"\managerRpo.ini"               ##Carrega configuracoes do arquivo ini para atribuir as variaveis
$cPathProtheus 		= $iniContent["ambiente"]["PathProtheus"] 	 ##Caminho do Protheus, nÃƒÂ£o colocar a ultima barra
$cPathProtheusRemoto 		= $iniContent["ambiente"]["PathProtheusRemoto"] 	 ##Caminho do Protheus, de um servidor remoto

$cPathRPO 			= $iniContent["ambiente"]["PathRPO"]         #"\apo"							##Nome da pasta raiz onde fica todos os RPO's
$cPathAtualizaRPO 	= $iniContent["ambiente"]["PathAtualizaRPO"] #"\atualizarpo" 					##caminho do RPO que serÃƒÂ¡ copiado para a produÃƒÂ§ÃƒÂ£o
$cPathBinarios		= $iniContent["ambiente"]["PathBinarios"]    # "\bin" 							##Caminho dos binÃƒÂ¡rios
$cRPOName 			= $iniContent["ambiente"]["RPOName"]         # "tttp120.rpo" 					##Nome do arquivo RPO
$aAppservers 		= $iniContent["ambiente"]["Appservers"].Split(',')      #@("appserver","appserver_Portal","appserver_slave1","appserver_slave2","appserver_slave3","appserver_slave4","appserver_slave5","appserver_slave6","appserver_slave7")	##Nome das pastas de cada serviÃƒÂ§o
$cEnvironment		= $iniContent["ambiente"]["Environment"]     #"Producao"						##Ambiente que serÃƒÂ¡ alterado (destino), appserver.ini e pastas devem ter o mesmo nome
$cPathTDS113        = $iniContent["patch"]["PathTDS113"]         #"C:\TOTVS\TotvsDeveloperStudio-11.3_Totvs" #Caminho do TDS, precisa estar instalado o TDSCLI 
$cServerHost        = $iniContent["patch"]["ServerHost"]         #"127.0.0.1" ##portal local 
$cServerPort        = $iniContent["patch"]["ServerPort"]         #"1242" ##porta de conexao com o appserver que sera usado para compilacao
$cServerBuild       = $iniContent["patch"]["ServerBuild"]        #"7.00.131227A" ##versao da build o binÃ¡rio
$cUserAdmin         = $iniContent["patch"]["UserAdmin"]          #"admin" #usuario para autenticar no protheus
$cUserPass          = $iniContent["patch"]["UserPass"]           # "totvs@2018" ##senha, caso em branco vai pedir toda aplicaÃ§Ã£o de path
$cEnvAplyRPO        = $iniContent["patch"]["EnvAplyRPO"]         #"atualizarpo" ##ambiente que serÃ¡ utilziado para aplicar o path
$cPathBinarioDefrag	= $iniContent["ambiente"]["PathBinarioDefrag"]			 # "appserverComp"  ## pasta do binario utilizado para o defrag
$cPathRPOCustom	= $iniContent["ambiente"]["PathRPOCustom"]			 # Define a pasta do rpo customizado


#------------------------------------------------------------------
#Variveis raramente alteradas 
$cAppserverNameFile = "appserver"                       ##Nome do arquivo .ini dos binÃƒÂ¡rios
$cAppserverIniFile  = $cAppserverNameFile+".ini"        ##Nome do arquivo .ini dos binÃƒÂ¡rios
$cGetPath           = Get-Location
$logfile            =  "$cGetPath\managerRPO.log"
#variaveis utilizadas para a compilacao via tdscli
$cPathTDS113Java    = $cPathTDS113+"\jre\bin\java.exe"
$cPathTDS113Plugin  = $cPathTDS113+"\plugins\org.eclipse.equinox.launcher_1.3.0.v20140415-2008.jar"
$cFilePath = ""#"C:\Users\totvs\Downloads\18-06-20-LIB_LABEL_15062018_P12-TTTP120\18-06-20-LIB_LABEL_15062018_P12-TTTP120.PTM"
$cRunCompile = "$cPathTDS113Java -jar $cPathTDS113Plugin -application br.com.totvs.tds.cli.tdscli -nosplash $cCommandsPathAply"



<#
FunÃƒÂ§ÃƒÂ£o resposnavel por trocar copiar de uma pasta para outra, gerar uma nova data
#>
function ChangeRPOFileInit{
    cls #limpa a tela
	
	
    $lReturn = $false
    ##define a variavel do RPO de origem
    $cRPOOrigtPath  = $cPathProtheus+$cPathRPO+$cPathAtualizaRPO
    $cRPOOrigFile   = $cPathProtheus+$cPathRPO+$cPathAtualizaRPO+"\"+$cRPOName
    ##define a pasta do rpo de destino
    $cRPODestPath   = $cPathProtheus+$cPathRPO+"\"+$cEnvironment+"\"+$cPathRPOCustom
    $cRPODestPathRemoto   = $cPathProtheusRemoto+$cPathRPO+"\"+$cEnvironment+"\"+$cPathRPOCustom
    
    $cRPODestFile   = $cPathProtheus+$cPathRPO+"\"+$cEnvironment+"\"+$cRPOName
	$cBINARIODefrag  = $cPathProtheus+$cPathBinarios+"\"+$cPathBinarioDefrag+"\appserver.exe"

 
    try {
	
            ##Verifica se a pasta do RPO de origem existe
			
            $lRetFun = Test-Path $cRPOOrigFile
            #Write-Host $lRetFun
            if (!$lRetFun){
                throw "Arquivo de origem nao  localizado $cRPOOrigFile" 
            }
            
            #Verifica se a pasta do ambiente de destino exist
            $lRetFun = Test-Path $cRPODestPath
            if (!$lRetFun){
                throw "Pasta destino nao localizada $cRPODestPath" 
            }

    
             #Verifica se a pasta do ambiente de destino exist
            if (Test-Path $cRPODestPathRemoto) {
               #Write-Host $lRetFun
                if (!$lRetFun){
                    throw "Pasta remota configurada nao localizada $cRPODestPathRemoto" 
                }
            }

         
            ##monta dados da nova pasta
            $cRPONewFolder = Get-Date -UFormat "%Y%m%d_%H%M%S"  #(Get-Date).toString("yyyymd_hhmmss")
            $cRPONewFiler   = $cRPODestPath+"\"+$cRPONewFolder
			$cRPONewFilerCustom   = $cRPODestPath+"\"+$cRPONewFolder+"\"+$cRPOName
            $cRPONewFilerAPO    = $cRPODestPath+"\"+$cRPONewFolder+"\"+$cRPOName
           
            
            
            ##parametros usados par ao robocopy
            $source      = $cRPOOrigtPath
            $dest        = $cRPONewFiler
            #$date        = Get-Date -UFormat "%Y%m%d_%H%M%S" 
            #$what        = @("/COPYALL") 
            $what        = @("") 
            #$options     = @("/R:1","/W:1","/LOG:$logfile") 
            $options     = @("$cRPOName","/R:1","/W:1","/S") 
            $cmdArgs     = @("$source","$dest",$what,$options)  
            robocopy @cmdArgs 
            
            
            $lRetFun = Test-Path $cRPONewFilerAPO
            if (!$lRetFun){
                throw "Arquivo nÃ£o copiado, nÃ£o localizada $cRPONewFilerAPO" 
            }
            
            ##altera os arquivos inis apontando para o novo caminho
            For ($i=0; $i -lt $aAppservers.Length; $i++) {
                ##monta variavel com o arquivo inicial
                
                $cIniFile       = $cPathProtheus+$cPathBinarios+"\"+$aAppservers[$i]+"\"+$cAppserverIniFile
                $cIniFileBak    = $cPathProtheus+$cPathBinarios+"\"+$aAppservers[$i]+"\"+$cAppserverNameFile+"_"+$cRPONewFolder+".bak"
                write-Host "Gerando backup do arquivo INI -> $cIniFileBak"
                Copy-Item $cIniFile $cIniFileBak
                
                #Verifica se o arquivo de backup do appserver foi copiado 
                $lRetFun = Test-Path $cIniFileBak
                if (!$lRetFun){
                    throw "Falha ao gerar arquivo de backup .INI no caminho -> $cIniFileBak" 
                }
				
                write-Host "Apontando para o novo RPO o arquivo INI $cIniFile" 
                Set-OrAddIniValue -FilePath $cIniFile  -keyValueList @{RPOCustom = $cRPONewFilerCustom}
            }
	    
	    

            ### TROCA PASTAS NO SERVIDOR REMOTO VIA CAMINHO DE REDE
            if (Test-Path $cRPODestPathRemoto) {           
                $cRPONewFilerRemoto   = $cRPODestPathRemoto+"\"+$cRPONewFolder
			    $cRPONewFilerCustomRemoto   = $cRPODestPathRemoto+"\"+$cRPONewFolder+"\"+$cRPOName
                $cRPONewFilerAPORemoto    = $cRPODestPathRemoto+"\"+$cRPONewFolder+"\"+$cRPOName
            

                ##parametros usados par ao robocopy
                $source      = $cRPOOrigtPath
                $dest        = $cRPONewFilerRemoto
                $what        = @("") 
                $options     = @("$cRPOName","/R:1","/W:1","/S") 
                $cmdArgs     = @("$source","$dest",$what,$options)  
                robocopy @cmdArgs 
            
            
                $lRetFun = Test-Path $cRPONewFilerRemoto
                if (!$lRetFun){
                    throw "Arquivo nÃ£o copiado, nÃ£o localizada $cRPONewFilerAPO" 
                }
            
                ##altera os arquivos inis apontando para o novo caminho
                For ($i=0; $i -lt $aAppservers.Length; $i++) {
                    ##monta variavel com o arquivo inicial
            
                

                    $cIniFile       = $cPathProtheusRemoto+$cPathBinarios+"\"+$aAppservers[$i]+"\"+$cAppserverIniFile
                    $cIniFileBak    = $cPathProtheusRemoto+$cPathBinarios+"\"+$aAppservers[$i]+"\"+$cAppserverNameFile+"_"+$cRPONewFolder+".bak"
                    
                    $lRetFunRem = Test-Path $cIniFile
                    if ($lRetFunRem){
                        write-Host "Gerando backup do arquivo INI -> $cIniFileBak"
                        Copy-Item $cIniFile $cIniFileBak
                
                        #Verifica se o arquivo de backup do appserver foi copiado 
                        $lRetFun = Test-Path $cIniFileBak
                        if (!$lRetFun){
                            throw "Falha ao gerar arquivo de backup .INI no caminho -> $cIniFileBak" 
                        }
				
                        write-Host "Apontando para o novo RPO o arquivo INI $cIniFile" 
                        Set-OrAddIniValue -FilePath $cIniFile  -keyValueList @{RPOCustom = $cRPONewFilerCustomRemoto}
                    }
                }
            }

	    
            
    } catch {
        
        $ErrorMessage = $_.Exception.Message
        #$FailedItem = $_.Exception.ItemName
        #Send-MailMessage -From ExpensesBot@MyCompany.Com -To WinAdmin@MyCompany.Com -Subject "HR File Read Failed!" -SmtpServer EXCH01.AD.MyCompany.Com -Body "We failed to read file $FailedItem. The error message was $ErrorMessage"
        #[System.Windows.MessageBox]::Show($ErrorMessage,'AtenÃ§Ã£o')
        Write-Error $ErrorMessage
        Break
    }
    Finally
    {
        $Time=Get-Date
        "$Time  | User:$env:USERNAME | Finalizado a Troca do RPO  " | out-file $logfile -append
        $lReturn = $true


    }
	
    return $lReturn
}       
    
        
    
<#
CHARLES REITZ - 25/06/2018
FunÃƒÂ§ÃƒÂ£o responsavel por loclaizar e setar os valores no ini
#>     
<#
CHARLES REITZ - 25/06/2018
FunÃƒÆ’Ã‚Â§ÃƒÆ’Ã‚Â£o responsavel por loclaizar e setar os valores no ini
#>   
function Set-OrAddIniValue
{
    Param(
        [string]$FilePath,
        [hashtable]$keyValueList
    )

    For ($i=0; $i -le 10; $i++) {
        $content = Get-Content $FilePath
    
        if ($content) {
            $keyValueList.GetEnumerator() | ForEach-Object {
                if ($content -match "^$($_.Key)=")
                {
                    $content= $content -replace "^$($_.Key)=(.*)", "$($_.Key)=$($_.Value)"
                }
                else
                {
                    $content += "$($_.Key)=$($_.Value)"
                }
            }

            #$content | Set-Content $FilePath
            break
        } 
        Start-Sleep -s 4
        
        Write-Host "Buscando dados do arquivo $FilePath - Tentativa $i"
    
    }


}

<#
CHARLES REITZ - 25/06/2018
Apresenta uma tela para slecionar uma determinada pasta
#>
Function Get-Folder($initialDirectory)

{
    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms")|Out-Null
    $folder = ""
    $foldername = New-Object System.Windows.Forms.FolderBrowserDialog
    #$foldername.rootfolder = "MyDocuments"

    if($foldername.ShowDialog() -eq "OK")
    {
        $folder += $foldername.SelectedPath
    }
    return $folder
}



<#Controle o menu de atuomacao #>   
function StartAutomate{
   
		ChangeRPOFileInit
}

			
StartAutomate
#AplytPathAndChangeRPO
#AplyPathTDSCli
#ChangeRPOFileInit

#lembretes de funcos abaixo
#Start-Job -ScriptBlock {
#  & java -jar MyProgram.jar >console.out 2>console.err
#}
