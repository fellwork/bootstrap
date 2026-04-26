. "$PSScriptRoot/../lib/animals.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($cond, $message) {
    if ($cond) { Write-Host "PASS: $message" -ForegroundColor Green }
    else       { Write-Host "FAIL: $message" -ForegroundColor Red; $script:failures++ }
}

# Registry has all 8 animals
$reg = Get-AnimalRegistry
Assert-True $reg.ContainsKey('fox')      "registry has fox"
Assert-True $reg.ContainsKey('owl')      "registry has owl"
Assert-True $reg.ContainsKey('turtle')   "registry has turtle"
Assert-True $reg.ContainsKey('octopus')  "registry has octopus"
Assert-True $reg.ContainsKey('hedgehog') "registry has hedgehog"
Assert-True $reg.ContainsKey('raccoon')  "registry has raccoon"
Assert-True $reg.ContainsKey('bee')      "registry has bee"
Assert-True $reg.ContainsKey('otter')    "registry has otter"

# Each animal has emoji + at least one phrase per situation it owns
foreach ($name in $reg.Keys) {
    Assert-True ($reg[$name].Emoji.Length -gt 0) "$name has emoji"
    Assert-True ($reg[$name].Phrases.Count -gt 0) "$name has phrases"
}

# Sprite animals are tagged
$sprites = Get-SpriteAnimals
Assert-Equal 6 $sprites.Count "exactly 6 sprite animals"
Assert-True ($sprites -contains 'raccoon') "sprite list includes raccoon"
Assert-True ($sprites -notcontains 'bee') "sprite list excludes bee"

# Get a random phrase
$phrase = Get-AnimalPhrase -Animal 'fox' -Situation 'repo-note'
Assert-True ($phrase.Length -gt 0) "fox returns a phrase"

# Error category mapping
$animal = Get-AnimalForErrorCategory -Category 'config-mismatch'
Assert-Equal 'raccoon' $animal "config-mismatch maps to raccoon"

$animal = Get-AnimalForErrorCategory -Category 'security'
Assert-Equal 'hedgehog' $animal "security maps to hedgehog"

if ($failures -eq 0) {
    Write-Host "`nAll animal tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures animal test(s) failed." -ForegroundColor Red
    exit 1
}
