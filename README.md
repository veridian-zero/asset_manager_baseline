\### osg-tools builder (in same folder as Dockerfile)

podman build -t osg-tools .



\### osg-tools runner

podman run --rm -v "${PWD}:/data" -e OSG\_NOTIFY\_LEVEL=INFO osg-tools .\\Gladiator\_Ajax.flt output\_null.osg





\### osg-inspector builder (in same folder as Dockerfile)

podman build -t osg-inspector .



\### osg-inspector runner (local file)

podman run --rm -v "${PWD}:/data" osg-inspector ./Gladiator\_Ajax.flt





\### osg-thumb (in same folder as Dockerfile)

podman build -t osg-thumb .



\### osg-thumb runner (front | rear | left | right | top) (white | slate | dark | light | green | #HexCode)

podman run --rm -v "${PWD}:/data:Z" osg-thumb ".\\Gladiator\_Ajax.flt" "media\\ajax\_rear.png" "rear" "white"





\### siso-indexer (in same folder as Dockerfile)

podman build -t siso-indexer .



\### siso db builder (in same directory as SISO-REF-010.xml

podman run --rm -v "${PWD}:/data:Z" siso-indexer python siso\_parse.py



\### Asset manager / siso enum lookup (run from top level folder)

podman run -d --name local\_asset\_manager -p 0.0.0.0:8000:8000 -v "${PWD}:/data:Z" -e DB\_PATH="/data/siso\_ref\_010\_v36/siso\_db.json" -e CATALOG\_PATH="/data/Trial\_Export/gladiator\_catalogue.csv" -e MODELS\_ROOT="/data/Trial\_Model\_Set/Gladiator/" -e MEDIA\_ROOT="/data/Trial\_Export/media" siso-indexer



podman stop local\_asset\_manager

podman rm local\_asset\_manager



\### Find IP of podman

wsl -d podman-machine-default ip addr show dev eth0



\### Powershell analyser

(uses podman - osg-inspector command and talks to the siso enum look up / asset manager)

(should be run from top level folder)



.\\process\_models.ps1 -SearchDir "D:\\Zanarkand\\Gladiator" -ModelsDir=".\\Models\\Gladiator\\" -OutputFile ".\\Gladiator\_Export\\model\_inventory.csv" -SisoApiUrl "http://172.21.20.219:8000" -MinConfidence "85"



Needs to be Powershell 7+ for parallel execution

winget install --id Microsoft.PowerShell



Get-ChildItem -Path ".\\Models" -Recurse -Filter ".\*.metadata.json" -Force | Remove-Item -Force



Get-ChildItem -Path ".\\Models" -Recurse -Directory -Filter ".\*\_thumbs" -Force | Remove-Item -Recurse -Force



Get-ChildItem -Path ".\\Models" -Recurse -Force | Where-Object { $\_.Name -like ".\*.metadata.json" -or ($\_.PSIsContainer -and $\_.Name -like ".\*\_thumbs") } | Remove-Item -Recurse -Force

