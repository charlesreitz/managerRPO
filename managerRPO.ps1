<#
CHARLES REITZ - 25/06/2018 
charles.reitz@totvs.com.br
Script para automatizar tarefaz para o sistema TOTVS Microsiga Protheus, sendo elas:
- Troca de RPO a quente informando um RPO de origem
- Aplicação de vários paths buscando de uma determinada pasta

PS: gentileza não remover as credencias de criação, seja gentil.
#>

Add-Type -AssemblyName System.Windows.Forms
##Set-ExecutionPolicy RemoteSigned ##COMANDO PARA HABILITAR A EXECUÇÃO DE SCRIPTS NO SERVIDOR, PRECISA RODAR COM ADMIN
#------------------------------------------------------------------
#CONFIGURACOES DO SCRIPT
#EFETUAR ALTERACAO DAS VARIAVEIS CONFORME NECESSIDAE DO AMBIENTE
#------------------------------------------------------------------

$cPathProtheus      = "E:\TOTVS12\Microsiga\Protheus"  ##Caminho do Protheus, nÃ£o colocar a ultima barra
$cPathRPO           = "\apo"                            ##Nome da pasta raiz onde fica todos os RPO's
$cPathAtualizaRPO   = "\atualizarpo"                    ##caminho do RPO que serÃ¡ copiado para a produÃ§Ã£o
$cPathBinarios      = "\bin"                            ##Caminho dos binÃ¡rios
$cRPOName           = "tttp120.rpo"                     ##Nome do arquivo RPO
#$aAppservers        = @("appserver","appserver_Portal","appserver_slave1","appserver_slave2","appserver_slave3","appserver_slave4","appserver_slave5","appserver_slave6","appserver_slave7")    ##Nome das pastas de cada serviÃ§o
$aAppservers       = @("")  ##Nome das pastas de cada serviÃ§o
$cEnvironment       = "producao"                        ##Ambiente que serÃ¡ alterado (destino), appserver.ini e pastas devem ter o mesmo nome
$cPathTDS113        = "E:\TOTVS12\TotvsDeveloperStudio-11.3" #Caminho do TDS, precisa estar instalado o TDSCLI 
$cServerHost        = "127.0.0.1" ##portal local 
$cServerPort  = "10500" ##porta de conexao com o appserver que sera usado para compilacao
$cServerBuild = "7.00.131227A" ##versao da build o binário
$cUserAdmin = "admin" #usuario para autenticar no protheus
$cUserPass =  "" ##senha, caso em branco vai pedir toda aplicação de path
$cEnvAplyRPO = "atualizarpo" ##ambiente que será utilziado para aplicar o path

#------------------------------------------------------------------
#Variveis raramente alteradas 
$cAppserverNameFile = "appserver"                       ##Nome do arquivo .ini dos binÃ¡rios
$cAppserverIniFile  = $cAppserverNameFile+".ini"        ##Nome do arquivo .ini dos binÃ¡rios
$cGetPath           = Get-Location
$logfile            =  "$cGetPath\managerRPO.log"
#variaveis utilizadas para a compilacao via tdscli
$cPathTDS113Java    = $cPathTDS113+"\jre\bin\java.exe"
$cPathTDS113Plugin  = $cPathTDS113+"\plugins\org.eclipse.equinox.launcher_1.3.0.v20140415-2008.jar"
$cFilePath = ""#"C:\Users\totvs\Downloads\18-06-20-LIB_LABEL_15062018_P12-TTTP120\18-06-20-LIB_LABEL_15062018_P12-TTTP120.PTM"
$cRunCompile = "$cPathTDS113Java -jar $cPathTDS113Plugin -application br.com.totvs.tds.cli.tdscli -nosplash $cCommandsPathAply"
    



<#
FunÃ§Ã£o resposnavel por trocar copiar de uma pasta para outra, gerar uma nova data
#>
function ChangeRPOFileInit{
    cls #limpa a tela
    $lReturn = $false
    ##define a variavel do RPO de origem
    $cRPOOrigtPath  = $cPathProtheus+$cPathRPO+$cPathAtualizaRPO
    $cRPOOrigFile   = $cPathProtheus+$cPathRPO+$cPathAtualizaRPO+"\"+$cRPOName
    ##define a pasta do rpo de destino
    $cRPODestPath   = $cPathProtheus+$cPathRPO+"\"+$cEnvironment
    $cRPODestFile   = $cPathProtheus+$cPathRPO+"\"+$cEnvironment+"\"+$cRPOName


    try {
            ##Verifica se a pasta do RPO de origem existe
            $lRetFun = Test-Path $cRPOOrigFile
            #Write-Host $lRetFun
            if (!$lRetFun){
                throw "Arquivo não localizado $cRPOOrigFile" 
            }
            
            #Verifica se a pasta do ambiente de destino exist
            $lRetFun = Test-Path $cRPODestPath
            #Write-Host $lRetFun
            if (!$lRetFun){
                throw "Pasta não localizada $cRPODestPath" 
            }
            
            ##monta dados da nova pasta
            $cRPONewFolder = Get-Date -UFormat "%Y%m%d_%H%M%S"  #(Get-Date).toString("yyyymd_hhmmss")
            $cRPONewFiler   = $cRPODestPath+"\"+$cRPONewFolder
            $cRPONewFilerAPO    = $cRPODestPath+"\"+$cRPONewFolder+"\"+$cRPOName
            
            
            # New-Item -ItemType directory -Path $cRPONewFiler -Force
            # Copy-item $cRPOOrigFile $cRPODestPath -Recurse -Force
            #Copy-Item $cRPOOrigFile -Destination $cRPONewFiler -Recurse -Force
            
            ##parametros usados par ao robocopy
            $source      = $cRPOOrigtPath   
            $dest        = $cRPONewFiler
            #$date        = Get-Date -UFormat "%Y%m%d_%H%M%S" 
            #$what        = @("/COPYALL") 
            $what        = @("") 
            #$options     = @("/R:1","/W:1","/LOG:$logfile") 
            $options     = @("*.*","/R:1","/W:1","/S") 
            $cmdArgs     = @("$source","$dest",$what,$options)  
            robocopy @cmdArgs 
            
            
            $lRetFun = Test-Path $cRPONewFilerAPO
            if (!$lRetFun){
                throw "Arquivo não copiado, não localizada $cRPONewFilerAPO" 
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
                Set-OrAddIniValue -FilePath $cIniFile  -keyValueList @{SourcePath = $cRPONewFiler}
            }
            
    } catch {
        
        $ErrorMessage = $_.Exception.Message
        #$FailedItem = $_.Exception.ItemName
        #Send-MailMessage -From ExpensesBot@MyCompany.Com -To WinAdmin@MyCompany.Com -Subject "HR File Read Failed!" -SmtpServer EXCH01.AD.MyCompany.Com -Body "We failed to read file $FailedItem. The error message was $ErrorMessage"
        #[System.Windows.MessageBox]::Show($ErrorMessage,'Atenção')
        Write-Error $ErrorMessage
        Break
    }
    Finally
    {
        $Time=Get-Date
        "Troca de RPO Realizada com Sucesso | $Time  | User:$env:USERNAME" | out-file $logfile -append
        $lReturn = $true
    }

    return $lReturn
}       
    
        
    
<#
CHARLES REITZ - 25/06/2018
FunÃ§Ã£o responsavel por loclaizar e setar os valores no ini
#>  
function Set-OrAddIniValue
{
    Param(
        [string]$FilePath,
        [hashtable]$keyValueList
    )

    $content = Get-Content $FilePath

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

    $content | Set-Content $FilePath
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



<#
CHARLES REITZ - 25/06/2018
Efetua a compilacao dos patchs em um determinado ambiente
#>
function AplyPathTDSCli{
    cls #limpa tela
    $lReturn = $false

    #http://tdn.totvs.com/pages/viewpage.action?pageId=201746065
    
     try {
         if ($cUserAdmin -eq ""){
             $cUserAdmin = Read-Host "Informe o usuário do sistema Protheus para aplicação do pacote"
         }

         if ($cUserPass -eq ""){
             $cUserPass = Read-Host "Informe a senha do sistema Protheus para aplicação do pacote" 
         }
         
         ##caso nao tiver dfinicao de pasta padrao abre tela para selecionar
         if ($cFilePath -eq ""){
             $cFilePath = Get-Folder
         }
         
         if ($cFilePath -eq ""){
            throw "Não foi informado pasta para buscar dos path" 
         }
         
         #aFilerGet-ChildItem -Path $cFilePath -Filter *TTTP120.PTM -Recurse -ErrorAction SilentlyContinue -Force
         #locations = Get-ChildItem -Path $cFilePath -Filter *TTTP120.PTM -Recurse -ErrorAction SilentlyContinue -Force | ? {!$_.psiscontainer}
         $locations = Get-ChildItem -Path $cFilePath -Filter *TTTP120.PTM -Recurse -ErrorAction SilentlyContinue -Force  
         
         $totalFilerAnalyse = $locations.Count
         if ($totalFilerAnalyse -eq 0){
             throw "Não foi informado pasta para buscar dos path" 
         }
         
         if ($totalFilerAnalyse -gt 50){
             throw "Muitos arquivos a serem aplicados. Total: $totalFilerAnalyse" 
         }
         

         #$confirmation = Read-Host "Pasta selecionada: $cFilePath | Sistema fará a busca e irá aplicar todos os paths com a extensão TTTP.PTM | Total de caminhos a serem analisados $totalFilerAnalyse `n Confirma? (Y/N)"
         #if ($confirmation -ne 'y' -or $confirmation -ne 'Y' ) {
         #  throw "Cancelado pelo operador" 
         #}

         $nCountFor = 1
         for($i = 0; $i -lt $totalFilerAnalyse; $i++){
            $cFilePath = $locations[$i].fullname
            if($cFilePath -ne ""){
                $cMsgPad = "Aplicando  patch $nCountFor / $totalFilerAnalyse | $cFilePath " 
                Write-Host  $cMsgPad
                $cMsgPad >> $logfile

                #$cCommandsPathAply = "patchapply serverType=AdvPL server=$cServerHost build=$cServerBuild port=$cServerPort user=$cUserAdmin psw=$cUserPass environment=$cEnvAplyRPO localPatch=T patchFile=$cFilePath applyOldProgram=F"
                $cCommandsPathAply = "patchapply serverType=AdvPL server=$cServerHost build=$cServerBuild port=$cServerPort user=$cUserAdmin psw=$cUserPass environment=$cEnvAplyRPO localPatch=T patchFile=$cFilePath applyOldProgram=F"
                Start-Process $cPathTDS113Java -ArgumentList '-jar', $cPathTDS113Plugin' -application br.com.totvs.tds.cli.tdscli -nosplash '$cCommandsPathAply -RedirectStandardError .\console_error.log -Wait 
                #-RedirectStandardOutput '.\console_out.log'
                if (Test-Path .\console_error.log){
                    $errorlog = Get-Content .\console_error.log
                    if ($errorlog.Length -ne 0 ){
                        throw "Falha ao aplicar path $errorlog" 
                    }
                }
            }
             $nCountFor += 1
         }
         
		 defragRPO #desfragmenta o RPO
		 
    } catch {
        
        $ErrorMessage = $_.Exception.Message
        #$FailedItem = $_.Exception.ItemName
        #Send-MailMessage -From ExpensesBot@MyCompany.Com -To WinAdmin@MyCompany.Com -Subject "HR File Read Failed!" -SmtpServer EXCH01.AD.MyCompany.Com -Body "We failed to read file $FailedItem. The error message was $ErrorMessage"
        #[System.Windows.MessageBox]::Show($ErrorMessage,'Atenção')
        Write-Error  $ErrorMessage
        Break
    }
    Finally
    {
        $Time=Get-Date
        "$Time  | User:$env:USERNAME | Finalizado aplicação de paths  " | out-file $logfile -append
        $lReturn = $true
       
    }

     
	
    return $lReturn
}

<#
CHARLES REITZ - 25/06/2017 
APLICA OS PATHS E TROCA 
#>
function AplytPathAndChangeRPO{
    $lReturn = $false

    try {
        AplyPathTDSCli
        ChangeRPOFileInit    
		defragRPO #desfragmenta o RPO
    }
    catch{
        $ErrorMessage = $_.Exception.Message
        #$FailedItem = $_.Exception.ItemName
        #Send-MailMessage -From ExpensesBot@MyCompany.Com -To WinAdmin@MyCompany.Com -Subject "HR File Read Failed!" -SmtpServer EXCH01.AD.MyCompany.Com -Body "We failed to read file $FailedItem. The error message was $ErrorMessage"
        #[System.Windows.MessageBox]::Show($ErrorMessage,'Atenção')
        Write-Error  $ErrorMessage
        Break
    }
    Finally{
        $Time=Get-Date
        "$Time  | User:$env:USERNAME | Finalizado aplicação de path e troca do RPO" | out-file $logfile -append
        $lReturn = $true
    }

	
   return $lReturn
}


<#
CHARLES REITZ - 25/06/2018
Apresentar o menu para o usuario escolher o que deseja fazer
#>
function Show-Menu
{
     param (
           [string]$Title = 'Escolha a opção desejada'
     )
     cls
     Write-Host "LOG disponível em -> $logfile"
     Write-Host "================ $Title ================"
     
     Write-Host "1: Trocar RPO Produção"
     Write-Host "2: Aplicar vários paths selecionado apenas uma pasta"
     Write-Host "3: Aplicar patchs e trocar RPO da produção "
	 Write-Host "4: Desfragmentar RPO "
     Write-Host "Q: Precione 'Q' to quit."
    
}

<#Controle o menu de atuomacao #>   
function StartAutomate{
    do
    {
    
         Show-Menu
         $input = Read-Host "Selecione a opção desejada"
         switch ($input)
         {
               '1' {
                        $confirmation = Read-Host "Confirma execução troca do RPO? (Y/N)"
                        if ($confirmation -eq 'y' -or $confirmation -eq 'Y' ) {
                            ChangeRPOFileInit
                        }
                    
               } '2' {
                    $confirmation = Read-Host "Confirma aplicação de path? (Y/N)"
                    if ($confirmation -eq 'y' -or $confirmation -eq 'Y' ) {
                         AplyPathTDSCli
                     }
                    

               } '3' {
                     $confirmation = Read-Host "Confirma aplicação de path e troca de RPO? (Y/N)"
                    if ($confirmation -eq 'y' -or $confirmation -eq 'Y' ) {
                         AplytPathAndChangeRPO
                     }
				} '4' {
                     $confirmation = Read-Host "Confirma aplicação de path e troca de RPO? (Y/N)"
                    if ($confirmation -eq 'y' -or $confirmation -eq 'Y' ) {
                         defragRPO
                     }

               } 'q' {
                    return
               } 'Q' {
                    return
               }
         }
         pause
         cls
    }
    until ($input -eq 'q')
}

<# Função responsável por desfragmentar o RPO #>
function defragRPO{

	   $cCommandsPathAply = "defragRPO serverType=AdvPL server=$cServerHost build=$cServerBuild port=$cServerPort user=$cUserAdmin psw=$cUserPass environment=$cEnvAplyRPO"
		Start-Process $cPathTDS113Java -ArgumentList '-jar', $cPathTDS113Plugin' -application br.com.totvs.tds.cli.tdscli -nosplash '$cCommandsPathAply -RedirectStandardError .\console_error.log -Wait 
		#-RedirectStandardOutput '.\console_out.log'
		if (Test-Path .\console_error.log){
			$errorlog = Get-Content .\console_error.log
			if ($errorlog.Length -ne 0 ){
				throw "Falha ao desfragmentar o RPO $errorlog" 
			}
		}
}

StartAutomate
#AplytPathAndChangeRPO
#AplyPathTDSCli
#ChangeRPOFileInit

#lembretes de funcos abaixo
#Start-Job -ScriptBlock {
#  & java -jar MyProgram.jar >console.out 2>console.err
#}
