{obj, uri, Synchronizer} = require './util/tools'
{Extension} = require './Extension'
{ExtensionPoint, ExtensionPointProvider} = require './Crawler.ExtensionPoints'
{CrawlerContext, ContextAware} = require './Crawler.Context'
{ExtensionPointConnector, RequestItemMapper,
Spooler, Completer, Cleanup, UserAgentProvider} = require './extensions/core'
{UserAgentProvider} = require './extensions/core.users'
{QueueConnector, QueueWorker} = require './extensions/core.queues'
{RequestStreamer} = require './extensions/core.streaming'
{QueueSystem} = require './QueueSystem'
{UrlFilter} = require './extensions/core.filter'
{Phase} = require './RequestItem.Phases'
{RequestItem} = require './RequestItem'
{LogHub, LogConfig} = require './Logging'
_ = require 'lodash'
fse = require 'fs-extra'
RateLimiter = require('limiter').RateLimiter
{Mixin} = require 'coffee-latte'
{Lifecycle} = require './Lifecycle.coffee'


class CrawlerLifecycle extends Lifecycle

  constructor:->
    super()
      # Start crawling. All queued commands will be executed after "commands.start" message
      # was sent to all listeners.
    @onStart =>
      @log.info? "Starting", tags: ['Crawler']
      @context.emit 'crawler:start'
      @commandQueueWorker = =>
        if _.isEmpty @commandQueue or not @isRunning() then return
        queuedCommands = @commandQueue
        @commandQueue = []
        command() for command in queuedCommands
      @commandQueueWorker = setInterval @commandQueueWorker, 500
      Promise.all (for extension in @extensions
        @log.info? "Starting", tags: [extension.name]
        extension.start())
      .then => @context.emit 'crawler:running'
    # Stop crawling. Unfinished {RequestItem}s will be brought into terminal phase {COMPLETE}, {CANCELED}, {ERROR}
    # with normal operation.
    # {UrlScheduler} and {QueueWorker} and all other extensions will receive the "commands.stop" message.
    # {QueueSystem} will be persisted, then the optional callback will be invoked.
    @onStop =>
      @log.info? "Stopping", tags: ['Crawler']
      # Stop all extensions and Scheduler
      @context.emit 'crawler:stop'
      checkForUnfinishedItems = =>
        unfinished = @qs.items().inPhases [Phase.READY, Phase.FETCHING, Phase.FETCHED]
        if _.isEmpty unfinished
          clearInterval @wdog
          @qs.save()
          clearInterval @commandQueueWorker
          @log.info? "Stopped", tags: ['Crawler']
          @context.emit 'crawler:stopped'
      # Make sure that items in processing are COMPLETED before stopping
      @wdog = setInterval checkForUnfinishedItems, 500
      Promise.all (for extension in @extensions
        @log.info? "Stopping", tags: [extension.name]
        extension.stop())


###
The Crawler coordinates execution of submitted {RequestItem} by applying all {Extension}s
matching the item's current phase.

All functionality for item handling, such as filtering, queueing, streaming, storing, logging etc.
is implemented as {Extension}s to {ExtensionPoint}s.

Extensions are added to extension points during initialization. Core extensions are added automatically,
user extensions are specified in the options of the Crawler's constructor.

The crawler defines an extension point for each distinct value of {ProcessingPhase}.
Each ExtensionPoint wraps the processing steps carried out when the item phase changes
to a new value. The phase transitions implicitly define a item flow illustrated in the
diagram below.

@example Configuration Parameters
    name      : "kermit"
    basedir   : "/tmp/sloth"
    extensions: [] # Clients can add extensions
    options   : # Options of each core extension can be customized here
      Logging : LogConfig.detailed
      Queueing   : {} # Options for the queuing system, see [QueueWorker] and [QueueConnector]
      Streaming: {} # Options for the [Streamer]
      Filtering  : {} # Options for item filtering, [RequestFilter],[DuplicatesFilter]
      Scheduling : {} # Options for the [Scheduler]
        maxWaiting: 50
        msPerUrl: 50

@event @crawler:start Fired when crawling is starting
@event @crawler:running Fired when crawler finished starting
@event @crawler:stop Fired when crawler initiates to stop all operations
@event @crawler:stopped Fired when crawler finished stopping

###
class Crawler extends Mixin
  @with Synchronizer, ExtensionPointProvider, CrawlerLifecycle

  # Create a new crawler with the given options
  # @param options [Object] The configuration for this crawler.
  # @see CrawlerConfig
  constructor: (options = {}) ->
    throw new Error "Please provide a name property in options. Was: #{options.name}" unless options.name
    throw new Error "Please provide a basedir property in options. Was: #{options.basedir}" unless options.basedir
    super options
    # Use default options where no user defined options are given
    @commandQueue =  []
    @name = options.name
    @config = new CrawlerConfig options
    @log = new LogHub(@config.options.Logging).logger()
    @qs = new QueueSystem
      filename: "#{@config.basePath()}/#{@config.options.Queueing.filename}",
      log:@log
    # Create the root context of this crawler
    @context = new CrawlerContext
      config : @config
      crawler: @ # re-expose this crawler
      log    : @log
      qs : @qs
    @scheduler = new Scheduler @context, @config

    @initializeExtensionPoints @context
    # Core extensions that need to run BEFORE user extensions
    @addExtensions [
      new ExtensionPointConnector
      new RequestItemMapper
      new QueueConnector @config.options.Queueing
      new QueueWorker @config.options.Queueing
      new UserAgentProvider
      ]
    # Add client extensions
    # TODO:30 Do not allow extensions on phase COMPLETE
    @log.debug? "Installing user extensions #{(ext.name for ext in @config.extensions)}", tags:['Crawler']
    @addExtensions @config.extensions
    # Core extensions that need to run AFTER client extensions
    @addExtensions [
      new RequestStreamer @config.options.Streaming
      new Spooler
      new Completer
      new Cleanup]

    initializeExtensions = =>
      for extension in @extensions
        @log.info? "Initializing #{extension}"
        extension.initialize(@context.fork())
        extension.verify()

    @qs.initialize =>
      # TODO:40 Move all commands on queue for execution as soon as crawler is initialized
      initializeExtensions()
      @start() if @config.autostart
    @log.info? @toString(), tags:['Crawler']

    # Usually this handler is considered back practice but in case of unhandled errors
    # of single items (in not so well behaved extensions :) general operation should continue.
    allowedErrors = new RateLimiter 1,2000
    process.on 'uncaughtException', (error) =>
      @log.error? "Caught an uncaught exception", {tags:['Uncaught'], error:error.toString(), stack:error.stack}
      if not allowedErrors.tryRemoveTokens 1
        @log.info? "Allowed uncaught error rate exceeded. Initiating shutdown"


  # Stop crawling and exit process.
  shutdown: ->
    @stop -> process.exit()

  on: (event, handler) ->
    @context.on event, handler

  # Create a new {RequestItem} and start its processing
  # @return [RequestItem] The created item
  crawl: (url, meta) ->
    if not @isRunning()
      @log.debug? "Queued GET #{url}. The queued command is transient and executed when start() is called"
      @commandQueue.push =>
        @log.debug? "Executing queued command <GET #{url}>"
        @crawl url,meta
    else
      item = new RequestItem url, meta, @log
      @log.trace? "GET #{url}", { tags:['Crawler'], item}
      @scheduleExecution Phase.INITIAL, item

  # Add the url to the {Scheduler}
  schedule: (url, meta) ->
    @scheduler.schedule url, meta

  hasWork:-> @qs.urls().count('scheduled') >0 and @qs.items().unfinished().length > 0

  execute:(command)->
    # A command is either executed on the crawler itself or it targets a specific extension
    target = if command.extension then @ExtensionPoint.getExtension @, command.extension else @
    executable = target[command.cmd]
    executable.apply target, command

  # Pretty print this crawler
  toString: ->
    asString = "Crawler with #{obj.print @config, 3}. Extensions =>"
    for extension in @extensions
      asString += "\n#{extension.toString()}"
    asString

###
  The central object for configuring an instance of {Crawler}.
  @private
###
class CrawlerConfig

  ###
  @param config [Object] The configuration parameters
  @option config [String] name The name of the crawler
  @option config [Boolean] autostart Whether the start command is issued after initialization
  @option config [String] basedir The base directory used for all data (logs, offline storage etc.)
  @option config [Array<Extension>] extensions An array of user {Extension}s to be installed
  @option config.options [Object] Queueing Options for {QueueWorker} and {QueueConnector}
  @option config.options [Object] Streaming Options for {RequestStreamer}
  @option config.options [Object] Filtering Options for {RequestFilter} and {UrlFilter}
  @option config.options [Object] Logging The configuration for the {LogHub}
  ###
  constructor: (config = {}) ->
    @name      = "kermit"
    @basedir   = "/tmp/sloth"
    @autostart = false
    @extensions = [] # Clients can add extensions
    @options   = # Options of each core extension can be customized here
      Logging   : LogConfig.detailed
      Queueing   :
        filename : "#{obj.randomId()}-queue" # Options for the queuing system, see [QueueWorker] and [QueueConnector]
        limits : []
      Streaming: {} # Options for the {Streamer}
      Filtering  : {} # Options for item filtering, [RequestFilter],[DuplicatesFilter]
      Scheduling  : {} # Options for URL scheduling [Scheduler]
    obj.merge @, config
    @options.Logging = switch
      when _.isFunction config.options?.Logging then config.options.Logging "#{@basePath()}/logs"
      when _.isObject config.options?.Logging then config.options.Logging
      else LogConfig.detailed "#{@basePath()}/logs"

  # @return [String] The configured base path of this crawler
  basePath: -> "#{@basedir}/#{@name}"

###

  The scheduler acts as a buffer for submitted URLs, which it will feed to the crawler
  according to the crawlers load.
  It receives URLs from clients and applies all configured filters (blacklist/whitelist)
  as well as duplicate prevention.
  The scheduler is an internal class controlled by the {Crawler} and should not be interacted
  with directly. It is exposed indirectly through the {CrawlerContext}.


  @todo Could be implemented as an extension as soon as extensions have lifecycle integration.

  @private
###
class Scheduler extends Mixin
  @with Synchronizer, ContextAware

  @defaultOptions: ->
    maxWaiting : 50
    interval : 500

  # @nodoc
  constructor: (@context, @config) ->
    super()
    @importContext @context
    @nextUrls = []
    @urlFilter = new UrlFilter @config.options.Filtering, @log
    @options = obj.overlay Scheduler.defaultOptions(), @config.options.Scheduling
    @context.on 'crawler:start', @start
    @context.on 'crawler:stop', @stop


  # @private
  # @nodoc
  schedule: (url, meta) ->
    @qs.urls().schedule url, meta unless url is null or not @urlFilter.isAllowed url, meta

  # Called by Crawler at startup
  # @nodoc
  start: =>
    @log.info? "Starting", tags:['Scheduler']
    pushUrls = =>
      waiting = @qs.items().waiting().length
      missing = @options.maxWaiting - waiting
      if missing > 0
        @synchronized =>
          if _.isEmpty @nextUrls
            @nextUrls = @nextUrls.concat @qs.urls().scheduled 500
          available = Math.min @nextUrls.length, missing
          for i in [1..available]
            # TODO:80 pop() has performance implications, migrate to fix size array with updating pointer
            # see https://gamealchemist.wordpress.com/2013/05/01/lets-get-those-javascript-arrays-to-work-fast/
            next = @nextUrls.pop()
            @crawler.crawl next.url, next.meta unless next is undefined or not @urlFilter.isAllowed next.url, next.meta
    @scheduler = setInterval pushUrls,  @options.interval # run regularly to feed new URLs


  stop: =>
    clearInterval @scheduler
    @log.info? "Stopping", tags: ['Scheduler']

module.exports = {
  Crawler
  ExtensionPoint
}
