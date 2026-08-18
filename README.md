<div align="center">

# Remote-Patch

远程补丁工具

[![Release](https://img.shields.io/github/release/TRSSo/Remote-Patch)](https://github.com/TRSSo/Remote-Patch/releases)

</div>

## 格式化命令

```sh
powershell -c 'Get-Item -Path *.ps1 | ForEach-Object { Set-Content -Path $_.FullName -Value (Invoke-Formatter -ScriptDefinition ((Get-Content -Path $_.FullName -Raw) -replace "`r`n","`n") -Settings @{Rules=@{PSUseConsistentIndentation=@{Enable=$true;Kind="space";IndentationSize=2}}}) -Encoding UTF8 }'
```
