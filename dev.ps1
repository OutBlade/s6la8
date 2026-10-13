# Run a command inside the s6la8 development container with the repo mounted
# at /work.  Usage: .\dev.ps1 make sim
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$image = if ($env:S6LA8_IMAGE) { $env:S6LA8_IMAGE } else { "s6la8-dev" }

docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
    docker build -t $image (Join-Path $here "docker")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

docker run --rm -v "${here}:/work" -w /work $image @args
exit $LASTEXITCODE
