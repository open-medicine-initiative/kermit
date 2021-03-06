{Extension} = require '../Extension'

class Histogrammer extends Extension

  constructor: ->
    super()
    @histogram = {}
    @urlCount = 0
    # collect url, title, keywords, number of links, content-length
    @on COMPLETE : (item) ->
        # https://www.npmjs.com/package/babyparse
        @histogram[item.url()] = item.pipeline().headers
        @urlCount++

module.exports = {Histogrammer}
