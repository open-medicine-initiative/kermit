{obj} = require './util/tools'
kermit = require './Crawler'
kermit = obj.merge kermit, require './RequestItem'
kermit = obj.merge kermit, require './Extension'
kermit = obj.merge kermit, require './Crawler.ExtensionPoints'
kermit.filters = require './extensions/core.filter'
kermit.ext = obj.merge {}, require './extensions/ext.discovery'
kermit.ext = obj.merge kermit.ext, require './extensions/ext.htmlprocessor'
kermit.ext = obj.merge kermit.ext, require './extensions/ext.offline'
kermit.ext = obj.merge kermit.ext, require './extensions/ext.monitoring'
kermit.logconf = require './Logging.conf'

module.exports = kermit