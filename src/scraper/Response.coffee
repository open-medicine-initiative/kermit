through = require 'through2'
{PassThrough} = require 'stream'
{HtmlExtractor} = require './Extractor.coffee'
{MemoryStream} = require './util/utils.coffee'

class Response

  constructor : () ->
    @incoming = new PassThrough() # stream.PassThrough serves as connector
    @data = []

  parser: () ->
    if !@extractor
      @extractor = new HtmlExtractor
      @incoming
        .pipe new MemoryStream @data
      @incoming.on 'end', =>
        @extractor.process @content()
    @extractor

  content : ->
    @data.join()

module.exports = {
  Response
}