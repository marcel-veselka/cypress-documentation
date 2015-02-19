config         = require("konfig")()
path           = require("path")
_              = require("lodash")
fs             = require("fs-extra")
Promise        = require("bluebird")
child_process  = require("child_process")
glob           = require("glob")
gulp           = require("gulp")
$              = require('gulp-load-plugins')()
gutil          = require("gulp-util")
inquirer       = require("inquirer")
NwBuilder      = require("node-webkit-builder")
yazl           = require("yazl")

fs = Promise.promisifyAll(fs)

require path.join(process.cwd(), "gulpfile.coffee")

distDir  = path.join(process.cwd(), "dist")
buildDir = path.join(process.cwd(), "build")

class Deploy
  constructor: ->
    if not (@ instanceof Deploy)
      return new Deploy()

    @version          = null
    @publisher        = null
    @publisherOptions = {}
    @platforms        = ["osx64"]
    @zip              = "cypress.zip"

  getVersion: ->
    @version ? throw new Error("Deploy#version was not defined!")

  setVersion: ->
    @log("#setVersion")

    @version = fs.readJsonSync(distDir + "/package.json").version

  getPublisher: ->
    aws = fs.readJsonSync("./aws-credentials.json")

    @publisher ?= $.awspublish.create
      bucket:          config.app.s3.bucket
      accessKeyId:     aws.key
      secretAccessKey: aws.secret

  prepare: ->
    @log("#prepare")

    p = new Promise (resolve, reject) ->
      ## clean/setup dist directories
      fs.removeSync(distDir)
      fs.ensureDirSync(distDir)

      ## copy root files
      fs.copySync("./package.json", distDir + "/package.json")
      fs.copySync("./config/app.yml", distDir + "/config/app.yml")
      fs.copySync("./lib/html", distDir + "/lib/html")
      fs.copySync("./lib/public", distDir + "/lib/public")
      fs.copySync("./nw/public", distDir + "/nw/public")

      ## copy coffee src files
      fs.copySync("./lib/cypress.coffee", distDir + "/src/lib/cypress.coffee")
      fs.copySync("./lib/controllers", distDir + "/src/lib/controllers")
      fs.copySync("./lib/util", distDir + "/src/lib/util")
      fs.copySync("./lib/routes", distDir + "/src/lib/routes")
      fs.copySync("./lib/cache.coffee", distDir + "/src/lib/cache.coffee")
      fs.copySync("./lib/id_generator.coffee", distDir + "/src/lib/id_generator.coffee")
      fs.copySync("./lib/keys.coffee", distDir + "/src/lib/keys.coffee")
      fs.copySync("./lib/logger.coffee", distDir + "/src/lib/logger.coffee")
      fs.copySync("./lib/project.coffee", distDir + "/src/lib/project.coffee")
      fs.copySync("./lib/server.coffee", distDir + "/src/lib/server.coffee")
      fs.copySync("./lib/socket.coffee", distDir + "/src/lib/socket.coffee")
      fs.copySync("./lib/updater.coffee", distDir + "/src/lib/updater.coffee")

      ## copy test files
      # fs.copySync("./spec/server/unit/konfig_spec.coffee", distDir + "/spec/server/unit/konfig_spec.coffee")
      # fs.copySync("./spec/server/unit/url_helpers_spec.coffee", distDir + "/spec/server/unit/url_helpers_spec.coffee")
      # fs.removeSync(distDir + "/spec/server/unit/deploy_spec.coffee")

      resolve()

    p.bind(@)

  convertToJs: ->
    @log("#convertToJs")

    ## grab everything in src
    ## convert to js
    new Promise (resolve, reject) ->
      gulp.src(distDir + "/src/**/*.coffee")
        .pipe $.coffee()
        .pipe gulp.dest(distDir + "/src")
        .on "end", resolve
        .on "error", reject

  obfuscate: ->
    @log("#obfuscate")

    ## obfuscate all the js files
    new Promise (resolve, reject) ->
      ## grab all of the js files
      files = glob.sync(distDir + "/src/**/*.js")

      ## root is src
      ## entry is cypress.js
      ## files are all the js files
      opts = {root: distDir + "/src", entry: distDir + "/src/lib/cypress.js", files: files}

      obfuscator = require('obfuscator').obfuscator
      obfuscator opts, (err, obfuscated) ->
        return reject(err) if err

        ## move to lib
        fs.writeFileSync(distDir + "/lib/cypress.js", obfuscated)

        resolve(obfuscated)

  cleanupSrc: ->
    @log("#cleanupSrc")

    fs.removeAsync(distDir + "/src")

  cleanupDist: ->
    @log("#cleanupDist")

    fs.removeAsync(distDir)

  cleanupBuild: ->
    @log("#cleanupBuild")

    fs.removeAsync(buildDir)

  runTests: ->
    new Promise (resolve, reject) ->
      ## change into our distDir as process.cwd()
      process.chdir(distDir)

      ## require cypress to get the require path's cached
      require(distDir + "/lib/cypress")

      ## run all of our tests
      gulp.src(distDir + "/spec/server/unit/**/*")
        .pipe $.mocha()
        .on "error", reject
        .on "end", resolve

  zipBuild: (platform) ->
    @log("#zipBuild: #{platform}")

    ## change this to something manual if you're using
    ## the task: gulp dist:zip
    version = @getVersion()

    zip = new yazl.ZipFile()

    root = "#{buildDir}/#{version}/#{platform}"

    files = glob.sync("#{root}/**/*", nodir: true)

    getFiles = ->
      _.map files, (file) ->
        fs.statAsync(file).then (c) ->
          ## dont add anything thats not a file!
          return if not c.isFile()

          ## make the name relative from the platform
          name = path.relative(root, file)
          zip.addFile(file, name)

    Promise.all(getFiles()).then =>

      new Promise (resolve, reject) =>
        output = zip.outputStream.pipe(fs.createWriteStream("#{root}/#{@zip}"))
        output.on "close", resolve

        zip.end()

  zipBuilds: ->
    @log("#zipBuilds")

    Promise.all _.map(@platforms, _.bind(@zipBuild, @))

  getQuestions: (version) ->
    [{
      name: "publish"
      type: "confirm"
      message: "Publish a new version?"
      default: true
    },{
      name: "version"
      type: "input"
      message: "Bump version? (current is: #{version})"
      default: ->
        a = version.split(".")
        v = a[a.length - 1]
        v = Number(v) + 1
        a.splice(a.length - 1, 1, v)
        a.join(".")
      when: (answers) ->
        answers.publish
    }]

  updateLocalPackageJson: (version) ->
    json = fs.readJsonSync("./package.json")
    json.version = version
    @writeJsonSync("./package.json", json)

  writeJsonSync: (path, obj) ->
    fs.writeJsonSync(path, obj, null, 2)

  ## add tests around this method
  updatePackages: ->
    @log("#updatePackages")

    new Promise (resolve, reject) =>
      json = distDir + "/package.json"
      pkg  = fs.readJsonSync(json)
      pkg.env = "production"

      ## publish a new version?
      ## if yes then prompt to increment the package version number
      ## display existing number + offer to increment by 1
      inquirer.prompt @getQuestions(pkg.version), (answers) =>
        ## set the new version if we're publishing!
        ## update our own local package.json as well
        if answers.publish
          pkg.version = answers.version
          @updateLocalPackageJson(answers.version)

        delete pkg.devDependencies
        delete pkg.bin

        if process.argv[3] is "--bin"
          pkg.snapshot = "lib/secret_sauce.bin"
          fs.copySync("./lib/secret_sauce.bin", distDir + "/lib/secret_sauce.bin")
        else
          fs.copySync("./lib/secret_sauce.coffee", distDir + "/src/lib/secret_sauce.coffee")

        @writeJsonSync(json, pkg)

        resolve()

  npmCopy: ->
    fs.copyAsync("./node_modules", distDir + "/node_modules")

  npmInstall: ->
    @log("#npmInstall")

    new Promise (resolve, reject) ->
      attempts = 0

      pathToPackageDir = _.once ->
        ## return the path to the directory containing the package.json
        packages = glob.sync(buildDir + "/**/package.json", {nodir: true})
        path.dirname(packages[0])

      npmInstall = ->
        attempts += 1

        child_process.exec "npm install --production", {cwd: pathToPackageDir()}, (err, stdout, stderr) ->
          if err
            return reject(err) if attempts is 3

            console.log gutil.colors.red("'npm install' failed, retrying")
            return npmInstall()
          else
            fs.writeFileSync(pathToPackageDir() + "/npm-install.log", stdout)

          ## promise-semaphore has a weird '/'' file which causes zipping to bomb
          ## so we must remove that file!
          fs.removeSync(pathToPackageDir() + "/node_modules/promise-semaphore/\\")

          resolve()

      npmInstall()

  build: ->
    @log("#build")

    nw = new NwBuilder
      files: distDir + "/**/*"
      platforms: @platforms
      buildDir: buildDir
      version: "0.11.6"
      buildType: => @getVersion()

    nw.on "log", console.log

    nw.build()

  getUploadDirName: (version, platform, override) ->
    (override or (version + "/" + platform)) + "/"

  uploadToS3: (platform, override) ->
    new Promise (resolve, reject) =>
      publisher = @getPublisher()
      options = @publisherOptions

      headers = {}
      headers["Cache-Control"] = "no-cache"

      version = @getVersion()

      gulp.src("#{buildDir}/#{version}/#{platform}/#{@zip}")
        .pipe $.rename (p) =>
          p.dirname = @getUploadDirName(version, platform, override)
          p
        .pipe publisher.publish(headers, options)
        .pipe $.awspublish.reporter()
        .on "error", reject
        .on "end", resolve

  uploadsToS3: (dirname) ->
    @log("#uploadToS3")

    uploadToS3 = _.partialRight(@uploadToS3, dirname)

    Promise.all _.map(@platforms, _.bind(uploadToS3, @))

  uploadFixtureToS3: ->
    @log("#uploadFixtureToS3")

    @uploadToS3("osx64", "fixture")

  createRemoteManifest: ->
    ## this isnt yet taking into account the os
    ## because we're only handling mac right now
    getUrl = (os) =>
      {
        url: [config.app.s3.path, config.app.s3.bucket, @version, os, @zip].join("/")
      }

    obj = {
      name: "cypress"
      version: @getVersion()
      packages: {
        mac: getUrl("osx64")
        win: getUrl("win64")
        linux64: getUrl("linux64")
      }
    }

    src = "#{buildDir}/manifest.json"
    fs.outputJsonAsync(src, obj).return(src)

  updateS3Manifest: ->
    @log("#updateS3Manifest")

    publisher = @getPublisher()
    options = @publisherOptions

    headers = {}
    headers["Cache-Control"] = "no-cache"

    new Promise (resolve, reject) =>
      @createRemoteManifest().then (src) ->
        gulp.src(src)
          .pipe publisher.publish(headers, options)
          .pipe $.awspublish.reporter()
          .on "error", reject
          .on "end", resolve

  dist: ->
    Promise.bind(@)
      .then(@prepare)
      .then(@updatePackages)
      .then(@setVersion)
      .then(@convertToJs)
      .then(@obfuscate)
      .then(@cleanupSrc)
      .then(@build)
      .then(@npmInstall)
      .then(@cleanupDist)

  fixture: (cb) ->
    @dist()
      .then(@zipBuilds)
      .then(@uploadFixtureToS3)
      .then(@cleanupBuild)
      .then ->
        @log("Fixture Complete!", "green")
        cb?()
      .catch (err) ->
        @log("Fixture Failed!", "red")
        console.log err

  log: (msg, color = "yellow") ->
    return if process.env["NODE_ENV"] is "test"
    console.log gutil.colors[color](msg)

  deploy: (cb) ->
    @dist()
      .then(@zipBuilds)
      .then(@uploadsToS3)
      .then(@updateS3Manifest)
      .then(@cleanupBuild)
      .then ->
        @log("Dist Complete!", "green")
        cb?()
      .catch (err) ->
        @log("Dist Failed!", "red")
        console.log err

module.exports = Deploy