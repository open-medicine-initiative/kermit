_ = require 'lodash'
util = require 'util'
URI = require 'urijs'
{MimebyFileExtension} = require './mimetypes'



class URIHelper

  # http://unicode.e-workers.de/entities.php
  HtmlEntities =
    '&amp;' : '&'
    '&gt;' : '>'
    '&lt;' : '>'
  HtmlEntityReplacer = new RegExp Object.keys(HtmlEntities).join("|"),"gi"
  HtmlEntityLookup = (match) -> HtmlEntities[match]

  wrapped = (value, prefix,suffix) ->
    if _.isEmpty value then "" else "#{prefix}#{value}#{suffix}"

  cleanUrl = (base, url) ->


  @replaceHtmlEntities : (url) ->
    url.replace HtmlEntityReplacer, HtmlEntityLookup

  # Process a set of URLs to produce a new set of cleaned, normalized and absolutized URLs.
  # Removes mailto/javascript, self-references and in-page anchors
  @clean : (base, url)  ->
    # Drop in-page anchors (#ref-to-anchor), self-references ("/"), mail (mailto) or calls to javascript
    return null if url is null or (_.isEmpty url) or (url.startsWith "#") or (url is "/") or (url.startsWith "mailto") or (url.startsWith "javascript")
    # Handle //somedomain.tld/somepath
    base = URI base
    # retain the same protocol if stated in abbreviated form
    url = url.replace /\/\//, base.scheme() + "://" if url.startsWith "//"
    url = URIHelper.replaceHtmlEntities url
    target = URI url
    target.normalize()
    # Handle relative urls with leading slash, i.e. /path/within/same/domain
    target = target.absoluteTo(base) if (url.startsWith "/") or (_.isEmpty target.tld())
    target.toString()

  @cleanAll: (base, urls) ->
    cleaned = []
    for url in urls
      clean = URIHelper.clean base, url
      cleaned.push clean unless clean is null
    cleaned

  @normalize: (url) -> URI(url).normalize().toString()

  # Translate an http URL to a filesystem URL
  # @todo Use hash for queries that exceed max length of file names in ext4
  @toLocalPath : (root = "", url) ->
    url = url.replace 'www', '' # 'www' is considered superfluous
    url = URIHelper.replaceHtmlEntities url
    uri = URI url
    uri.normalize()
    domainWithoutTld = uri.domain().replace ".#{uri.tld()}", ''
    subdomain = wrapped uri.subdomain(), '/', ''
    query = wrapped uri.query(), '[', ']'
    uri.segment("index.html") if (!uri.suffix() or not MimebyFileExtension[uri.suffix()])
    lastDot = uri.path().lastIndexOf '.'
    augmentedPath = [uri.path().slice(0, lastDot), query, uri.path().slice(lastDot)].join('');
    fullpath = "#{root}/#{uri.tld()}/#{domainWithoutTld}#{subdomain}#{augmentedPath}"
    URI(fullpath).readable()


class Files
  path = require 'path'
  fs = require 'fs'

  @exists : (fsId) ->
    try
      stats = fs.statSync fsId
      stats?
    catch err
      false

class ObjectHelper

  @addProperty: (name, value, object) ->
    object ?= {}
    object[name] ?= value
    object
  @print : (object, depth = 2, colorize = false) ->
    util.inspect object, false, depth, colorize
  @merge : (a,b) ->
    _.merge a , b , (a,b) -> switch
      when _.isArray(b) and not _.isEmpty a then b.concat a
      when _.isArray b then b
  @overlay : (a,b) ->
    _.merge a , b , (a,b) -> if _.isArray a then b
  @randomIndex : (upperBound) ->
    (Math.random() * upperBound) % upperBound
  @randomId : (length=8) ->
    # Taken from: https://coffeescript-cookbook.github.io/chapters/strings/generating-a-unique-id
    id = ""
    id += Math.random().toString(36).substr(2) while id.length < length
    id.substr 0, length

###

  Wrapper around synchronize.js - can be used as Mixin as well.

  https://mixmax.com/blog/node-fibers-using-synchronize-js
###
class Synchronizer
  sync = require 'synchronize'

  synchronized: (fn) -> sync.fiber fn
  await: sync.await
  defer: sync.defer

module.exports =
  uri: URIHelper
  obj : ObjectHelper
  files: Files
  Synchronizer: Synchronizer
  streams: require './tools.streams'
