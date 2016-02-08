{Phase} = require '../RequestItem'
storage = require '../QueueManager'
{Extension} = require '../Extension'
RateLimiter = require('limiter').RateLimiter
{obj} = require '../util/tools'
_ = require 'lodash'

# The Queue Connector establishes a system of queues where each state
# of the RequestItem state machine is represented in its own queue.
# It also enriches each item, such that its state transitions
# are propagated to the queuing system automatically.
class QueueConnector extends Extension

  # @nodoc
  constructor: () ->
    super INITIAL : @apply

  # Create a queue system and re-expose in context
  initialize: (context) ->
    super context
    @queue = context.queue

  # @nodoc
  updateQueue : (item) =>
    @queue.update(item)

  # Enrich each item with methods that propagate its
  # state transitions to the queue system
  apply: (item) ->
    @queue.insert item
    item.onChange 'phase', @updateQueue

# Process items that have been SPOOLED for fetching.
# Takes care that concurrency and rate limits are met.
class QueueWorker extends Extension

  @defaultOpts = () ->
    limits : [
        pattern : /.*/
        to : 5
        per : 'second'
        max : 5
    ]

  # https://www.npmjs.com/package/simple-rate-limiter
  constructor: (opts = {}) ->
    super {}
    @opts = obj.merge QueueWorker.defaultOpts(), opts

    # 'second', 'minute', 'day', or a number of milliseconds

  # @nodoc
  initialize: (context) ->
    super context
    @queue = context.queue # Request state is fetched from the queue
    @items = context.items # Request object is resolved from shared item map
    @limits = new RateLimits @opts.limits, @context.log, @queue # Rate limiting is applied here
    @spooler = setInterval @processRequests, 100 # Request spooling runs regularly
    @batch = [] # Local batch of items to be put into READY state

  # This is run at intervals to process waiting items
  # @private
  processRequests : () =>
    # Transition SPOOLED items into READY state unless parallelism threshold is reached
    @proceed @items[item.id] for item in @localBatch()

  # @nodoc
  localBatch: () ->
    currentBatch = _.filter @batch, (item) -> item.phase is 'SPOOLED'
    if not _.isEmpty currentBatch then currentBatch else @batch = @queue.spooled(100)

  # @nodoc
  proceed : (item) ->
    item.ready() if @limits.isAllowed item.url()

  # Stop the continuous execution of item spooling
  shutdown: ->
    clearInterval @spooler


###
  Wrapper for rate limit configurations passed as options to the {QueueWorker}
  @private
  @nodoc
###
class RateLimits

  constructor: (limits =[], @log, queue) ->
    @limits = (new Limit limitDef, queue for limitDef in limits)

  # Check whether applicable rate limits allow this URL to pass
  isAllowed : (url) ->
    for limit in @limits
      return limit.isAllowed() if limit.matches url
    throw new Error "No limit matched #{url}"

###
  @nodoc
  @private
###
class Limit

  # @nodoc
  constructor: (@def, @queue) ->
    @regex = @def.pattern
    @limiter = new RateLimiter @def.to , @def.per

  # @nodoc
  isAllowed: ->
    @limiter.tryRemoveTokens(1) and @queue.itemsProcessing(@regex) < @def.max

  # @nodoc
  matches: (url) ->
    url.match @regex

module.exports = {
  QueueConnector
  QueueWorker
}