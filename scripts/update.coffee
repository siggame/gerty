# Description:
#   Posts updates to status.megaminerai.com
#
# Commands:
#   hubot update <component> to <status>; <title>: <message> - Post a new status update
#

_ = require "underscore"
git = require "nodegit"
moment = require "moment"
path = require "path"
promisify = require "promisify-node"
slug = require "slug"
tmp = require "tmp"
yaml = require "js-yaml"
fse = promisify(require("fs-extra"))

# Configuration Options
config =
    repo_url: process.env.HUBOT_STATUS_REPO
    layout: "update"
    categories: _ ["arena", "food", "gameserver", "git", "visualizer", "webserver"]
    tags: _ ["OK", "Warning", "Down"]

class UpdateError
    ###
    An Error class for throwing
    ###
    constructor: (@message) ->

joinString = (char, _lst) ->
    ###
    Joins a list of strings together, separated by 'char's
    ###
    maybeJoin = (x, y) -> if x == "" then y else x + char + y
    _lst.reduce maybeJoin, ""


validateUpdate = (update) ->
    ###
    Validates an update object to ensure it has necessary fields
    ###

    # Ensure we're using a real category
    if not config.categories.contains(update.category)
        choices = joinString ", ", config.categories
        throw new UpdateError("Bad category. Please choose one of [#{choices}]")

    # Ensure we're using a real tag
    if not config.tags.contains(update.status)
        choices = joinString ", ", config.tags
        throw new UpdateError("Bad status. Please choose one of [#{choices}]")

    # Ensure we have a title
    if not update.title?
        throw new UpdateError("Please provide a title for the update.")

    # Ensure we have a title
    if not update.author?
        throw new UpdateError("Please provide an author for the update.")


updateStatus = (msg, tmpPath, update) ->
    ###
    Update a Jekyll status site
    ###

    # Check that our options are OK
    validateUpdate update

    # Current time
    date = moment()
    u = do date.unix
    o = do date.utcOffset

    # Commit author details
    author = git.Signature.create update.author, "siggame@mst.edu", u, o
    committer = git.Signature.create "Gerty", "siggame@mst.edu", u, o

    # YAML front matter for post
    frontMatter = yaml.safeDump
        layout: config.layout
        category: update.category
        tags: update.status
        date: date.format 'YYYY-MM-DD HH:mm:ss ZZ'

    # File bits
    fileName = "#{date.format 'YYYY-MM-DD'}-#{slug update.title}.md"
    fileContent = "---\n#{frontMatter}---\n\n#{update.message}\n"

    # Repo bits
    repo = null
    remote = null
    index = null
    oid = null

    # Set up SSH creds for cloning
    cloneOptions =
        remoteCallbacks:
            credentials: (url, userName) ->
                git.Cred.sshKeyFromAgent userName

    # Clone the repo
    git.Clone.clone(config.repo_url, tmpPath, cloneOptions)

        .then (repoResult) ->
            # Save the repo
            repo = repoResult

        .then () ->
            # Write our update file
            posts_dir = path.join repo.workdir(), "_posts"
            filePath = path.join posts_dir, fileName
            fse.writeFile filePath, fileContent

        .then () ->
            # Get the repo's index
            repo.openIndex()

        .then (indexResult) ->
            # Read the index
            index = indexResult
            index.read(1)

        .then () ->
            # Add our file to the index
            filePath = path.join "_posts", fileName
            index.addByPath filePath

        .then () ->
            # Update the index
            index.write()

        .then () ->
            # Create our new tree for the commit
            index.writeTree()

        .then (oidResult) ->
            # Get the reference (hash) for HEAD
            oid = oidResult
            git.Reference.nameToId(repo, "HEAD")

        .then (head) ->
            # Get the HEAD commit
            repo.getCommit(head)

        .then (parent) ->
            # Make the commit!
            m = "Update status for #{update.category}"
            repo.createCommit "HEAD", author, committer, m, oid, [parent]

        .then (ref) ->
            # Report our great success
            msg.reply "Committed update for #{update.category} (#{ref})"

        .then () ->
            # Get the "origin" remote
            repo.getRemote("origin")

        .then (remoteResult) ->
            remote = remoteResult

            # Set up credentials to push to "origin"
            remote.setCallbacks
                credentials: (url, userName) ->
                    git.Cred.sshKeyFromAgent userName

            # Set up connection to push to "origin"
            remote.connect git.Enums.DIRECTION.PUSH

        .then () ->
            # Push!
            remote.push ["refs/heads/master:refs/heads/master"],
                null,
                repo.defaultSignature(),
                "Push to master"

        .then () ->
            # Report our success
            msg.reply "#{update.category} status updated to #{update.status}"

        .catch (reason) ->
            # Or if it didn't work, report our error
            msg.reply "Uh oh... #{reason}"

        .done () ->
            # Now we're done with the repo, and we can delete it.
            fse.remove tmpPath, (err) ->
                if err
                    msg.reply "Error deleting #{tmpPath}: #{err}"
                msg.reply "Done!"


module.exports = (robot) ->

    unless config.repo_url?
        robot.logger.warning 'HUBOT_STATUS_REPO environment variable is not set'

    robot.respond /update (.*) to (.*); (.+): (.+)$/i, (msg) ->

        unless config.repo_url?
            msg.reply "I 'unno what to clone. Please set HUBOT_STATUS_REPO."
            return

        update =
            author: msg.message.user.name
            category: msg.match[1]
            status: msg.match[2]
            title: msg.match[3]
            message: msg.match[4]

        tmpOptions =
            prefix: "gerty-clone-tmp"

        tmp.dir tmpOptions, (err, path, cleanupCallback) ->
            try
                updateStatus msg, path, update
            catch error
                console.log "Encountered an error!"
                msg.reply error.message
