_ = require 'lodash'
util = require 'util'
URI = require 'urijs'

module.exports =
  uri:
    normalize: (url) -> URI(url).normalize().toString()
    create: (url) -> URI(url)
  obj :
    print : (object, depth = 2, colorize = false) ->
      util.inspect object, false, depth, colorize
    merge : (a,b) ->
      _.merge a , b , (a,b) -> if _.isArray b then b.concat a
    overlay : (a,b) ->
      _.merge a , b , (a,b) -> if _.isArray a then b
    randomId : (length=8) ->
      id = ""
      id += Math.random().toString(36).substr(2) while id.length < length
      id.substr 0, length
  streams: require './tools.streams.coffee'