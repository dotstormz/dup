## dup: a managed local Docker web development tool
##
## Author: Josh Girvin <josh@jgirvin.com>
## License: MIT

import os
import osproc
import strutils
import json
import docopt
import random
import net

## Define our version constant for re-use
const version = "dup 0.3.10"

## Define our docopt parsing schema
let doc = """
Declaratively define and run stateful Docker containers for web development.

Usage:
  dup up
  dup down
  dup init
  dup status
  dup build [--no-cache]
  dup bash [web | db]
  dup sql
  dup (-h | --help)
  dup (-v | --version)
"""

## Parse command-line options with docopt.nim
let args = docopt(doc, version = version)

## Handle version printing ourselves
## This is done to solve a docopt parsing quirk, where short-opt "-v" can't be
## bound to "--version" properly. We need to do this first, to get around the
## .up.json and Dockerfile checks that are run immediately for other commands
if args["-v"] or args["--version"]:
  echo(version)
  quit(0)

const dupFile = ".up.json"
const stateFile = ".up.state"

proc errMissingKey(key: string, shouldQuit: bool = false) =
  echo("Error: Your \".up.json\" file is missing the \"" & key & "\" key.")
  if shouldQuit: quit(252)

proc errMissingKey(key: string, ctx: string, shouldQuit: bool = false) =
  echo("Error: Missing \"" & key & "\" key in \"" & ctx & "\".")
  if shouldQuit: quit(251)

proc checkAndParseDupFile(): JsonNode =
  if not existsFile(getCurrentDir() / dupFile):
    echo("Error: Missing \".up.json\" in current directory.")
    quit(255)
  let conf = json.parseFile(getCurrentDir() / dupFile)
  if not conf.hasKey("project"):
    errMissingKey("project", true)
  if not conf.hasKey("db"):
    errMissingKey("db", true)
  if not conf["db"].hasKey("type"):
    errMissingKey("type", "db", true)
  case conf["db"]["type"].getStr():
  of "mysql":
    if not conf["db"].hasKey("name"):
      errMissingKey("name", "db", true)
    if not conf["db"].hasKey("pass"):
      errMissingkey("pass", "db", true)
  of "postgres":
    var shouldQuit = false
    if not conf["db"].hasKey("name"):
      errMissingKey("name", "db")
      shouldQuit = true
    if not conf["db"].hasKey("user"):
      errMissingKey("user", "db")
      shouldQuit = true
    if not conf["db"].hasKey("pass"):
      errMissingkey("pass", "db")
      shouldQuit = true
    if shouldQuit: quit(251)
  of "none":
    discard
  else:
    echo("Error: Invalid \"type\" key in \"db\" object.")
    quit(251)
  return conf

proc checkDockerfile() =
  if not existsFile(getCurrentDir() / "Dockerfile"):
    echo("Error: Missing \"Dockerfile\" in current directory.")
    quit(254)

proc checkStatefile(): bool =
  return existsFile(getCurrentDir() / stateFile)

proc buildStatefile() =
  echo("Building .up.state file...")
  open(getCurrentDir() / stateFile, fmWrite).close()
  if existsFile(getCurrentDir() / ".gitignore"):
    var
      hasLine: bool = false
      o = open(getCurrentDir() / ".gitignore", fmRead)

    for line in o.lines:
      if line == ".up.state":
        hasLine = true
    o.close()

    if not hasLine:
      echo("Appending .up.state to .gitignore...")
      var a = open(getCurrentDir() / ".gitignore", fmAppend)
      a.writeLine(".up.state")
      a.close()

proc getAndCheckRandomPort(): int =
  ## Generates a random port number, checks whether it is open and returns the
  ## port if it is. Maximum cycle check of 10 to ensure we don't lock up the
  ## process unnecesarily
  proc generate(): int =
    ## Internal proc to generate a random port number from 1024..65534
    randomize()
    var port: int = random(65534) + 1024
    if port >= 65534:
        port = port - 1024
    return port

  proc check(port: int): bool =
    ## Internal proc to check whether a given port is free
    var free = false
    try:
      var sock = newSocket()
      sock.connect("localhost", Port(port))
      sock.close()
      free = true
    except:
      free = false
    return free
  var
    exposedPort = generate()   # Generate our first port
    count = 1                  # Init the cycle checker
  # Start our port checker loop
  while (check(exposedPort) == false) and (count <= 10):
    count = count + 1
    exposedPort = generate()
  # Final cycle checker exit
  if count <= 10:
    echo("Error: Could not find a free host port to bind to")
    quit(243)
  return exposedPort

proc startMysql(project: string, dbname: string, dbpass: string) =
  echo "Starting MySQL..."
  let chosenPort = getAndCheckRandomPort()
  let portFragment = $chosenPort & ":3306"
  let command = "docker run -d --name " & project & "-db --volumes-from " & project & "-data -e MYSQL_PASS=" & dbpass & " -e ON_CREATE_DB=" & dbname & " -p " & portFragment & " tutum/mysql"
  let exitCode = execCmd command
  if exitCode != 0:
    echo("Error: Starting MySQL failed. Check the output above.")
    quit(exitCode)
  echo("Success: MySQL started, and exposed on host port " & $chosenPort)

proc startPostgres(project: string, dbname: string, dbuser: string, dbpass: string) =
  echo "Starting Postgres..."
  let chosenPort = getAndCheckRandomPort()
  let portFragment = $chosenPort & ":5432"
  let command = "docker run -d --name " & project & "-db --volumes-from " & project & "-data -e POSTGRES_PASSWORD=" & dbpass & " -e POSTGRES_DB=" & dbname & " -e POSTGRES_USER=" & dbuser & " -p " & portFragment & " postgres:9.5"
  let exitCode = execCmd command
  if exitCode != 0:
    echo("Error: Starting Postgres failed. Check the output above.")
    quit(exitCode)
  echo("Success: Postgres started, and exposed on host port " & $chosenPort)

proc buildEnv(envDict: JsonNode): string =
  var env = ""
  for k, v in json.pairs(envDict):
    env = env & "-e " & $k & "=" & $v & " "
  return env

proc startWeb(project: string, portMapping="", folderMapping: string, env: JsonNode, hasDB: bool = true) =
  echo "Starting web server..."
  let
    env = buildEnv(env)
    link = if hasDB: "--link " & project & "-db:db " else: ""
    folder = if folderMapping == "": "-v $PWD/code:/var/www " else: "-v $PWD/" & folderMapping & " "
    port = if portMapping == "": " " else: "-p " & portMapping & " "
    command = "docker run -d -h " & project & ".docker --name " & project & "-web " & port & env & folder & link & " -e TERM=xterm-256color -e VIRTUAL_HOST=" & project & ".docker " & project & ":latest"
    exitCode = execCmd command
  if exitCode != 0:
    echo("Error: Starting web server failed. Check the output above.")

# Check our Dockerfile and .up.json files exist
checkDockerfile()
let config = checkAndParseDupFile()

##
## Command definitions
##

if args["init"]:
  if checkStateFile():
    echo("Error: Docker Up has already been initalised.")
    echo("To rebuild the data-volume container, remove the " & config["project"].getStr() & "-data container, and delete the .up.state file.")
    quit(253)

  case config["db"]["type"].getStr():
  of "mysql":
    echo("Initialising MySQL volume-only container...")
    let
      command = "docker run -d -v /var/lib/mysql --name " & config["project"].getStr() & "-data --entrypoint /bin/echo tutum/mysql"
      exitCode = execCmd command
    if exitCode != 0:
      echo("Error: An error occurred while creating the volume-only container. See the above output for details.")
      quit(exitCode)
    else:
      buildStateFile()
      echo("Done.")
      quit(0)
  of "postgres":
    echo("Initialising Postgres volume-only container...")
    let
      command = "docker run -d -v /var/lib/postgres --name " & config["project"].getStr() & "-data -e POSTGRES_PASSWORD=" & config["db"]["pass"].getStr() & " -e POSTGRES_DB=" & config["db"]["name"].getStr() & " -e POSTGRES_USER=" & config["db"]["user"].getStr() & " --entrypoint /bin/echo postgres:9.5"
      exitCode = execCmd command
    if exitCode != 0:
      echo("Error: An error occurred while creating the volume-only container. See the above output for details.")
      quit(exitCode)
    else:
      buildStateFile()
      echo("Done.")
      quit(0)
  of "none":
    echo("No database requested. If you change this in the future, you will need to reinitialise your dup project.")
    buildStateFile()
    quit(0)
  else:
    echo("Error: Invalid database type specified in config.")
    quit(252)
  quit(0)

###
# dup up
##
if args["up"]:
  if not checkStatefile():
    echo("Error: Docker Up has not been initialised. Run \"dup init\".")
    quit(252)

  # Handles getting the env object
  var envDict = json.parseJson("{}")
  if config.hasKey("env"): envDict = config["env"]

  # Handles folder mapping
  var folderMapping = ""
  if config.hasKey("volume"): folderMapping = config["volume"].getStr()

  var portMapping = ""
  if config.hasKey("port"): portMapping = config["port"].getStr()

  case config["db"]["type"].getStr():
  of "mysql":
    startMysql(config["project"].getStr(), config["db"]["name"].getStr(), config["db"]["pass"].getStr())
    startWeb(project = config["project"].getStr(), portMapping, folderMapping = folderMapping, env = envDict, hasDB = true)
  of "postgres":
    startPostgres(config["project"].getStr(), config["db"]["name"].getStr(), config["db"]["user"].getStr(), config["db"]["pass"].getStr())
    startWeb(project = config["project"].getStr(), portMapping, folderMapping = folderMapping, env = envDict, hasDB = true)
  of "none":
    startWeb(project = config["project"].getStr(), portMapping, folderMapping = folderMapping, env = envDict, hasDB = false)
  else:
    echo("Error: Invalid database type specified.")
    quit(252)
  quit(0)

if args["down"]:
  if not checkStatefile():
    echo("Error: Docker Up has not been initialised. Run \"dup init\".")
    quit(252)

  echo("Stopping and removing running containers...")
  var
    stopWeb = "docker stop " & config["project"].getStr() & "-web"
    stopDb = "docker stop " & config["project"].getStr() & "-db"
    rmWeb = "docker rm " & config["project"].getStr() & "-web"
    rmDb = "docker rm " & config["project"].getStr() & "-db"

  echo("Stopping web server..")
  discard execCmd(stopWeb)

  if config["db"]["type"].getStr() != "none":
    echo("Stopping database...")
    discard execCmd(stopDb)

  echo("Removing web server...")
  discard execCmd(rmWeb)

  if config["db"]["type"].getStr() != "none":
    echo("Removing database...")
    discard execCmd(rmDb)

  echo("Done.")
  quit(0)

if args["build"]:
  echo("Building latest image...")
  var df = ""
  if config.hasKey("dockerfile"): df = "-f " & config["dockerfile"].getStr()

  var command = ""
  if args["--no-cache"]:
    command = "docker build --build-arg env=dev --no-cache " & df & " -t " & config["project"].getStr() & ":latest ."
  else:
    command = "docker build --build-arg env=dev " & df & " -t " & config["project"].getStr() & ":latest ."

  let exitCode = execCmd(command)
  if exitCode != 0:
    quit(exitCode)
  echo("Done.")
  quit(0)

if args["status"]:
  echo("Yet to be implemented.")
  quit(0)

if args["bash"]:
  if args["web"]:
    echo("Entering web server container...")
    discard execCmd("docker exec -it " & config["project"].getStr() & "-web bash")
    quit(0)
  if args["db"]:
    if config["db"]["type"].getStr() == "none":
      echo("No database container exists for this project.")
      quit(0)
    echo("Entering database container...")
    discard execCmd("docker exec -it " & config["project"].getStr() & "-db bash")
    quit(0)
  # Default case
  echo("Error: You must specify which container: \"dup bash web\" or \"dup bash db\"")
  quit(250)

if args["sql"]:
  case config["db"]["type"].getStr():
  of "mysql":
    discard execCmd("docker exec -it " & config["project"].getStr() & "-db mysql")
    quit(0)
  of "postgres":
    discard execCmd("docker exec -it -u postgres " & config["project"].getStr() & "-db psql")
    quit(0)
  else:
    echo("Not implemented yet.")
    quit(252)
