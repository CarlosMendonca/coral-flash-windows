Experimental PowerShell script for flashing the [Coral Dev Board](https://coral.ai/products/dev-board) on Windows. This can be used as an alternative to flash.sh while flashing the board according to the [documentation](https://coral.ai/docs/dev-board/reflash/).

# Usage
Usage is similar to the original flash.sh script, but follows PowerShell conventions:
```powershell
Get-Help .\flash.ps1 -Full
```

Execution policy should be set to unrestricted for this script to work:
```powershell
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
```

It's better if `flashboot.exe` is on the path, which can be done with:
```powershell
$env:Path += ";C:\<path_to_fastboot_dir>"
```

Alternatively the path to `fastboot.exe` can be specified with:
```powershell
.\flash.ps1 -fb C:\<path_to_fastboot_dir>
```

To enable extra information, turn verbose mode on with:
```powershell
$VerbosePreference = 'Continue'
```
