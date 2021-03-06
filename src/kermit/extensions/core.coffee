{Extension} = require '../Extension'
{UserAgent} = require './core.users.coffee'

###
  Adds listeners to the items such that each phase transition will
  trigger execution of the respective {ExtensionPoint}
###
class ExtensionPointConnector extends Extension

  # @nodoc
  constructor: ->
    super()
    @on INITIAL : (item) =>
      item.context = @context
      item.onChange 'phase', (item) => @context.processItem item


# Handle phase transition {INITIAL} -> {SPOOLED}
class Spooler extends Extension

  # @nodoc
  constructor: ->
    super()
    @on INITIAL : (item) -> item.spool()

# Handle phase transition {FETCHED} -> {COMPLETE}
class Completer extends Extension

  # @nodoc
  constructor: ->
    super()
    @on FETCHED : (item) -> item.complete() unless item.isError()

###
  Add capability to lookup a {RequestItem} by its id.

  @note This is used to find the living item instance for a given persistent state stored in {RequestItemStore}.
###
class RequestItemMapper extends Extension

  # @nodoc
  constructor: ->
    super()
    @on INITIAL : (item) => @items[item.id()] = item

  # Expose a map that allows to lookup a {RequestItem} object by id
  initialize: (context) ->
    super context
    @items = {}
    context.share "items", @items

###

  Sets a {UserAgent} on the {RequestItem}.

  @note The {UserAgent} is used by {RequestStreamer} to add request headers, cookies etc.

  @todo Choose randomly from a set of UserAgents
  @todo Persistence

###


# Run cleanup on all terminal phases
class Cleanup extends Extension

  # @nodoc
  constructor: ->
    super()
    @on
      COMPLETE : @complete
      CANCELED : @canceled
      ERROR : @error

  # Do cleanup work to prevent memory leaks
  complete: (item) ->
    delete @context.items[item.id()] # Remove from Lookup table to allow GC
    @context.qs.completed item # Remove from
    item.cleanup()
    @log.trace? item.toString(), tags:['Cleanup']

  # Do cleanup work to prevent memory leaks
  error: (item) ->
    delete @context.items[item.id()] # Remove from Lookup table to allow GC
    item.cleanup()

  # Do cleanup work to prevent memory leaks
  canceled: (item) ->
    delete @context.items[item.id()] # Remove from Lookup table to allow GC
    @log.trace? item.toString(), tags:['Cleanup']
    item.cleanup()

module.exports = {
  ExtensionPointConnector
  RequestItemMapper
  Spooler
  Completer
  Cleanup
}
