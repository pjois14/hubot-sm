###
Copyright 2016 Hewlett-Packard Development Company, L.P.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
Software distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and limitations under the License. 
###


_ = require 'lodash'
Config = require '../lib/config'
SM = require '../lib/smworker'
async = require 'async'
S = require('string')
moment = require 'moment'
Cha=require 'cha-ui'
g_enable_auth=false
verbs = []
module.exports = (robot) ->
  # set logging options
  winstonLogger = require ('winston')
  consoleOpts = {
    colorize: true,
    timestamp: true,
    level: process.env.LOG_LEVEL || 'debug'
  }
  transports = [new(winstonLogger.transports.Console)(consoleOpts)]
  if process.env.FLUENTD_HOST && process.env.FLUENTD_PORT
    FLUENTD_RECONNECT_DEFAULT = 600000
    FLUENTD_DEFAULT_TIMEOUT = 10
    logConfig = {
      host: process.env.FLUENTD_HOST,
      port: process.env.FLUENTD_PORT,
      timeout: process.env.FLUENTD_TIMEOUT || FLUENTD_DEFAULT_TIMEOUT,
      reconnectInterval: process.env.FLUENTD_RECONNECT || FLUENTD_RECONNECT_DEFAULT
    }
    FluentTransport = require('fluent-logger').support.winstonTransport()
    messagePrefix = process.env.FLUENTD_MSG_PREFIX || 'hubot-sm'
    transports.push(new FluentTransport(messagePrefix,logConfig))
  winstonLogger.configure({
    transports: transports,
    exitOnError: false
  })
  winstonLogger.setLevels(winstonLogger.config.syslog.levels)
  robot.logger = winstonLogger
  sessiontimeout=process.env.SESSTIONTIMEOUT
  if !sessiontimeout
    sessiontimeout="30m"
  console.log('start to load sm-cmd.coffee')
  if not robot.sm_ext
    SmExt = require "../lib/sm-#{robot.adapterName}"
    robot.sm_ext = new SmExt(robot)
  if not robot.Cha
    Cha.Framework.initHubot robot
    path = require("path").join __dirname, "../template/cha-tpls.yaml"
    Cha.Framework.init(path, robot.adapterName)
    robot.Cha = Cha
    console.log("successfully init chat-ui from:"+path.toString()) 
  # check that hubot-enterprise is loaded
  if not robot.e
    console.log('hubot-enterprise not present, cannot run')
    return
  # register integration
  auth_method = null
  if "enable" == process.env.HUBOT_ENTERPRISE_AUTH
    robot.logger.debug('hubot enterprise authentication is enabled')  
    g_enable_auth=true
    default_ins = Config.get "sm.servers.default"
    auth_url = Config.get "sm.servers.#{default_ins}.auth_url"
    if auth_url == null or auth_url==undefined
      console.log('hubot enterprise authentication is enabled, but auth_url did not give')
      return
    if  robot.e.auth != null && robot.e.auth.create_basic_auth_config != null && robot.e.auth.create_basic_auth_config != undefined
      verb = "GET"
      auth_method = robot.e.auth.create_basic_auth_config auth_url, verb, sessiontimeout
      robot.logger.debug('Use create_basic_auth_config to create auth config for:'+auth_url+" and sessiontimeout is:"+sessiontimeout)
    else
      auth_method={
        type: "basic_auth",
        params: {
        endpoint: auth_url
        }
      }
      robot.logger.debug('Use the auth_url:'+auth_url)    
  else
    robot.logger.debug('hubot enterprise authentication is disabled')
  robot.e.registerIntegration({short_desc: "slack integration with service manager"}, auth_method )
  #robot.logger.debug('hubot-sm-enterprise initialized successfully')
  console.log('hubot-sm-enterprise initialized successfully')
  #register get functions
  verbs.push("get");
  robot.e.create {product: 'sm', verb: 'get', entity: 'incident',
  regex_suffix:{re: '(.*)', optional: false},
  help: 'Retrieve the details of an incident by incident ID (e.g. IM10001)', type: 'respond',example:'IM10001'}, (resp,auth)->
     robot.logger.debug( 'sm get incident callback function is called with:'+resp.message+ ' \n with auth.secrets:'+auth.secrets)
     match = /([\w\d]+)(?:\s+on\s+([\w\d]+))?/i.exec resp.match[1]
     if not match
       resp.send ["Please use the correct syntax: 'sm get incident [ID]'.","To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return
     id=match[1]
     ins = match[2] or Config.get "sm.servers.default"
     username = null
     password = null
     if g_enable_auth and auth!=null and auth!=undefined and auth.secrets!=null and auth.secrets!=undefined
       usertoken=getAuthInfo(auth.secrets.token)
       username=usertoken.username
       password=usertoken.password
     SM.incident.get(id, ins, username, password)
       .then (r)->
         #msg = robot.sm_ext.formatRecord r.body.Incident
         msg = new robot.Cha.Framework.Message 'incidentformat', r.body.Incident 
         msg.channel = resp.message.room
         resp.send msg
      .catch (r) ->
         robot.logger.debug(r)
         msg = robot.sm_ext.buildSlackMsgFromSmError "Failed to retrieve incident #{id}", resp.message.room, r
         #robot.emit 'slack.attachment', msg
         msg.channel = resp.message.room
         resp.send msg
     
     info_data=
       "id":id
     info_msg=new robot.Cha.Framework.Message 'get_incident_info', info_data
     info_msg.channel = resp.message.room 
     resp.send info_msg
     
  #register assign functions
  verbs.push("assign");
  robot.e.create {product: 'sm', verb: 'assign', entity: 'incident',
  regex_suffix:{re: '(.*)', optional: false},
  help: 'Assign or reassign an incident to a person ([person] can be an email address, SM username, or Slack username)', type: 'respond',example:'IM10008 falcon'}, (resp, auth)->
     robot.logger.debug( 'sm assign incident callback function is called with:'+resp+ '\n with auth:'+auth)
     match = /([\w\d]+)\s+([\S]+)(?:\s+on\s+([\w\d]+))?/i.exec resp.match[1]
     if not match
       resp.send ["Please use the correct syntax: 'sm assign incident [ID] [person]'.","To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return
     id=match[1]
     people = match[2]
     orginal_people = people
     ins = match[3] or Config.get "sm.servers.default"
     assign_data=
       "id":id
       "orginal_people": orginal_people
     if people.indexOf("@") < 0
       robot.e.adapter.exec(resp,'usersList')
         .then (userlist) ->
           users = [people]
           email = null
           for user in userlist
             if (_.includes(users, user.name))
               email=user.email
               break;
           robot.logger.debug('get email for user:'+ people+" =>"+email)
           if email != null
             people =email
           username = null
           password = null
           if g_enable_auth and auth!=null and auth!=undefined and auth.secrets!=null and auth.secrets!=undefined
             usertoken=getAuthInfo(auth.secrets.token)
             username=usertoken.username
             password=usertoken.password
           SM.incident.assign(id, people, ins, resp.message.user.email_address, username, password)
           .then (r)->
             #resp.reply "Incident #{id} was assigned to #{orginal_people}."
             info_msg=new robot.Cha.Framework.Message 'assign_incident_ok', assign_data 
             info_msg.channel = resp.message.room 
             resp.send info_msg  
           .catch (r) ->
             msg = robot.sm_ext.buildSlackMsgFromSmError "Failed to assign Incident #{id} to #{orginal_people}", resp.message.room, r
             resp.send msg
            

     info_msg=new robot.Cha.Framework.Message 'assign_incident_info', assign_data 
     info_msg.channel = resp.message.room 
     resp.send info_msg     
     
  #register resolve functions
  verbs.push("resolve");
  robot.e.create {product: 'sm', verb: 'resolve', entity: 'incident',
  regex_suffix:{re: '(.*)', optional: false},
  help: 'Resolve an incident by providing a solution', type: 'respond',example:'IM10008 "fixed by reset password"'}, (resp,auth)->
     robot.logger.debug( 'sm resolve incident callback function is called with:'+resp+ '\n with auth:'+auth)
     match = /([\w\d]+)\s+\"([^\n]*)\"(?:\s+on\s+([\w\d]+))?/i.exec resp.match[1]
     if not match
       resp.send ["Please use the correct syntax: `sm resolve incident [ID] \"[solution]\"'.","To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return
     id = match[1]
     solution = match[2]
     ins = match[3] or Config.get "sm.servers.default"
     username = null
     password = null
     file_data=
       "id":id
     if g_enable_auth and auth!=null and auth!=undefined and auth.secrets!=null and auth.secrets!=undefined
       usertoken=getAuthInfo(auth.secrets.token)
       username=usertoken.username
       password=usertoken.password   
     SM.incident.resolve(id, solution, ins, resp.message.user.email_address, username, password)
       .then (r)->
          #resp.reply "Incident #{id} was resolved."
          info_msg=new robot.Cha.Framework.Message 'resolve_incident_ok', file_data 
          info_msg.channel = resp.message.room 
          resp.send info_msg
       .catch (r) ->
          robot.logger.debug(r)
          msg = robot.sm_ext.buildSlackMsgFromSmError "Failed to resolve the incident #{id}", resp.message.room, r
          #robot.emit 'slack.attachment', msg
          resp.send msg

     info_msg=new robot.Cha.Framework.Message 'resolve_incident_info', file_data 
     info_msg.channel = resp.message.room 
     resp.send info_msg

  #register addactivity functions
  verbs.push("addactivity");
  robot.e.create {product: 'sm', verb: 'addactivity', entity: 'incident',
  regex_suffix:{re: '(.*)', optional: false},
  help: 'Add an activity to an incident', type: 'respond',example:'IM10008 "solve this incident in slack"'}, (resp, auth)->
     robot.logger.debug( 'sm addactivity incident callback function is called with:'+resp+ '\n with auth:'+auth)
     match = /([\w\d]+)\s+\"([^\n]*)\"(?:\s+on\s+([\w\d]+))?/i.exec resp.match[1]
     if not match
       resp.send ["Please use the correct syntax: 'sm addactivity incident [ID] \"[activity]\"'.","To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return
     id = match[1]
     activity = match[2]
     ins = match[3] or Config.get "sm.servers.default"
     username = null
     password = null
     file_data=
       "id":id
     if g_enable_auth and auth!=null and auth!=undefined and auth.secrets!=null and auth.secrets!=undefined
       usertoken=getAuthInfo(auth.secrets.token)
       username=usertoken.username
       password=usertoken.password   
     SM.incident.addActivity(id, activity, ins, resp.message.user.email_address, username, password)
        .then (r)->
          #resp.reply "The activity was added to incident #{id}."
          info_msg=new robot.Cha.Framework.Message 'addactivity_incident_ok', file_data 
          info_msg.channel = resp.message.room 
          resp.send info_msg
        .catch (r) ->
          robot.logger.debug(r)
          msg = robot.sm_ext.buildSlackMsgFromSmError "Failed to add the activity for incident #{id}", resp.message.room, r
          #robot.emit 'slack.attachment', msg
          resp.send msg

     info_msg=new robot.Cha.Framework.Message 'addactivity_incident_info', file_data 
     info_msg.channel = resp.message.room 
     resp.send info_msg

  #register create functions
  verbs.push("create");
  robot.e.create {product: 'sm', verb: 'create', entity: 'incident',
  regex_suffix:{re: '(.*)', optional: false},
  help: 'Create an incident as well as a Slack channel for the new incident (you can omit -channel to not create a Slack channel)', type: 'respond',example:'"can not login QC" -channel'}, (resp, auth)->
     robot.logger.debug( 'sm create incident callback function is called with:'+resp+ '\n with auth:'+auth)
     match = /\"([^\n]*)\"(?:\s+(-channel))?(?:\s+on\s+([\w\d]+))?/i.exec resp.match[1]
     if not match
       resp.send ["Please use the correct syntax: 'sm create incident \"[description]\" -channel'. (\"-channel\" is optional.)","To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return
     title = match[1]
     createchannel=match[2] or false
     ins = match[3] or Config.get "sm.servers.default"
     if false!=createchannel
       createchannel=true
     username = null
     password = null
     if g_enable_auth and auth!=null and auth!=undefined and auth.secrets!=null and auth.secrets!=undefined
       usertoken=getAuthInfo(auth.secrets.token)
       username=usertoken.username
       password=usertoken.password 
     SM.incident.createIncident(title, ins, createchannel, resp.message.user.email_address, username, password)
       .then (r)->
         robot.logger.debug(r)
         #resp.reply "Incident #{r.body.Incident.IncidentID} was created!"
         msg = new robot.Cha.Framework.Message 'create_incident_ok', r.body.Incident 
         msg.channel = resp.message.room
         resp.send msg
         msg = new robot.Cha.Framework.Message 'incidentformat', r.body.Incident 
         msg.channel = resp.message.room
         resp.send msg
       .catch (r) ->
         robot.logger.debug(r)
         msg = robot.sm_ext.buildSlackMsgFromSmError "Failed to create incident", resp.message.room, r
         #robot.emit 'slack.attachment', msg
         resp.send msg
     msg = new robot.Cha.Framework.Message 'create_incident_info'
     msg.channel = resp.message.room
     resp.send msg
     
  #register update functions
  verbs.push("update");
  robot.e.create {product: 'sm', verb: 'update', entity: 'incident',
  regex_suffix:{re: '(.*)', optional: false},
  help: 'Update certain fields of an incident', type: 'respond',example:'IM10008 category=incident assignee=falcon'}, (resp, auth)->
     robot.logger.debug( 'sm update incident callback function is called with:'+resp+ '\n with auth:'+auth)
     params = resp.match[1]
     #check id
     m = /([\d\w]+)(.*)/i.exec params
     id = m[1] if m?
     if not id
       resp.send ["Please specify an Incident `ID`", "To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return
     params = m[2].trim()
     if not params
       resp.send ["Can not update with nothing", "Please specify what you want to update in `field`=`value` formats", "To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return

     m = /(.*)?on\s+([\w\d]+)$/i.exec params
     ins = if m
        params = m[1]
        m[2]
     else
        Config.get "sm.servers.default"

     # check instance
     data = Config.get "sm.servers.#{ins}"
     if not data
       resp.send ["Please specify a validate Service Manager Instance name", "To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return
     if not params
       resp.send ["Can not update with nothing", "Please specify what you want to update in `field`=`value` formats", "To learn more about all supported commands, enter 'sm'."].join("\r\n")
       return


     # Clean up utf8 quotations
     params = params.replace  /[\u201C|\u201D]/g, '"'
     params = params.replace /[\u2019|\u2018]/g, "'"
     reg = /([\w\d\.]+)=(?:(?:'([^']+)')|(?:"([^"]+)")|(\S+))/gi
     m = reg.exec params
     keyValues = {}
     while(m)
       # console.log m
       value = m[2] or m[3] or m[4]
       keyValues[m[1]] = value
       m = reg.exec params
     robot.logger.debug("Update Incident data")
     robot.logger.debug(keyValues)
     username = null
     password = null
     file_data=
       "id":id
       "error":""
     if g_enable_auth and auth!=null and auth!=undefined and auth.secrets!=null and auth.secrets!=undefined
       usertoken=getAuthInfo(auth.secrets.token)
       username=usertoken.username
       password=usertoken.password 
     SM.incident.update(id, keyValues, ins, username,password)
       .then (r)->
         robot.logger.debug(r.body.Messages)
         wrongmsg = null;
         for msg in r.body.Messages
           if msg.indexOf(":{")!=-1 and msg.indexOf("}")!=-1
             nextpos=msg.indexOf(msg.indexOf(":{")+3,":")
             attrname=msg.substring(msg.indexOf(":{")+3,nextpos);
             robot.logger.debug( "find ignore field:"+attrname)
             if keyValues[attrname] != null
               wrongmsg=msg
         if wrongmsg == null
           #resp.reply "Incident #{id} was updated"
           info_msg=new robot.Cha.Framework.Message 'update_incident_ok', file_data 
           info_msg.channel = resp.message.room 
           resp.send info_msg
         else
           resp.reply "Incident #{id} was updated, but some fields may be wrong."+wrongmsg
           #file_data.error=wrongmsg
           #info_msg=new robot.Cha.Framework.Message 'update_incident_error', file_data
           ##info_msg.text=info_msg.text.replace(/&quot;/g,'"') 
           #info_msg.channel = resp.message.room 
           #resp.send info_msg
       .catch (r) ->
         robot.logger.debug(r)
         errmsg = robot.sm_ext.buildSlackMsgFromSmError "Failed to update incident", resp.message.room, r
         #robot.emit 'slack.attachment', errmsg
         resp.send errmsg

     info_msg=new robot.Cha.Framework.Message 'update_incident_info', file_data 
     info_msg.channel = resp.message.room 
     resp.send info_msg
     
  #register attach functions
  verbs.push("attach-conversation");
  robot.e.create {product: 'sm', verb: 'attach-conversation', entity: 'incident',
  regex_suffix:{re: '(.*)', optional: false},
  help: 'Attach the entire conversation history of the current channel to an incident', type: 'respond',example:'IM10008'}, (resp, auth)->
     robot.logger.debug( 'sm attach-conversation for incident callback function is called with:'+resp+ '\n with auth:'+auth)
     match = /([\w\d]+)\s*(?:on (.+))?/i.exec resp.match[1]
     if not match
       resp.send helpAttach.join("\r\n")
       return
     id = match[1]
     # robot.logger.debug res.match
     ins = match[2] or Config.get "sm.servers.default"

     # robot.logger.debug "SM instance is #{ins}"
     serverEndpoint = Config.get("sm.servers.#{ins}.endpoint")
     [server, port] = serverEndpoint.split ":"
     account = Config.get("sm.servers.#{ins}.account")
     robot.logger.debug("To attach conversation to #{id} on #{serverEndpoint}")
     latest_ts = 0
     result = []
     has_more = true
     # TODO: this is Slack specific
     robot.logger.debug( "start to get userList")
     file_data=
       "id":id
     robot.e.adapter.exec(resp,'usersList')
       .then (userlist) ->
         robot.logger.debug( "start to attach with message:"+resp.message)
         channel = resp.message.room
         async.waterfall([
           (cb)->
             async.whilst(
               ()->  has_more
               (cb1)->
                 robot.sm_ext.getHistory(channel, latest_ts)
                   .then (data)->
                     has_more = data.has_more
                     robot.logger.debug("get conversation history message:"+ data.messages)
                     result = _.concat(result, data.messages)
                     latest_ts = _.last(data.messages).ts if data.messages and data.messages.length > 1
                     cb1(null)
                   .catch (r) ->
                     robot.logger.debug( "gethistory error "+r)
                     resp.send "Fail to attaching converstaion to Service Manager Incident #{id}.\n*Reason*: #{r}"
               (err)->
                 cb(null, result)
             )
      
           (messages,cb)->
             robot.logger.debug("incident id is #{id}")
             robot.logger.debug("message count is #{messages.length}")
             texts = []
             texts.push(reviseMessage(m,userlist)) for m in messages
             texts = texts.reverse()
             incident_data =
               "review.detail": ["attach conversation"],
               "JournalUpdates": texts
             username = null
             password = null
             if g_enable_auth and auth!=null and auth!=undefined and auth.secrets!=null and auth.secrets!=undefined
               usertoken=getAuthInfo(auth.secrets.token)
               username=usertoken.username
               password=usertoken.password 
             SM.incident.update(id, incident_data, ins, username, password)
               .then (data)->
                 #resp.reply "The conversation was attached to incident #{id}."
                 info_msg=new robot.Cha.Framework.Message 'attach_incident_ok', file_data 
                 info_msg.channel = resp.message.room 
                 resp.send info_msg
                 cb(data)
               .catch (data) ->
                 robot.logger.debug("Failed attaching conversation")
                 robot.logger.debug(data.body)
                 # res.reply "Failed to attach conversation: #{data}"
                 slackMsg = robot.sm_ext.buildSlackMsgFromSmError "Failed to attach conversation to #{id}", channel, data
                 #robot.emit 'slack.attachment', slackMsg
                 resp.send slackMsg
                 cb(data)
             #resp.reply "Attaching the conversation to Incident #{id}..."
             info_msg=new robot.Cha.Framework.Message 'attach_incident_info', file_data 
             info_msg.channel = resp.message.room 
             resp.send info_msg
         ])
       .catch (err) ->
         robot.logger.error("attach-conversation failed due to when try to get usersList meet exception:"+err)

  # helpers
  # Method to resolve user name from
  reviseMessage = (message,users)->
    result = ""
    for item in users
      robot.logger.debug("get userinfo id:"+item.id+" name:"+item.name)
    user_name = message.username
    robot.logger.debug("start to revise message for message username:"+message.username+" user:"+message.user+" text:"+message.text)
    if message.username == undefined
      #user = robot.brain.userForId message.user
      user = null
      for item in users
        if item.id==message.user
          user=item
          break;
      if user != undefined and user != null
        user_name=user.name 
        robot.logger.debug("find user id "+message.user+" name is:"+user_name)
      else
        user_name=message.user
    text = message.text
    robot.logger.debug("get the name is:"+user_name)
    #m = /<@([\w\d]+)(\|([\w]+))?>/ig.exec text
    m = /<@([\w\d]+)(\|([\w]+))?>/ig.exec text
    # robot.logger.debug text
    if m
      if m[2]==undefined
        #user = robot.brain.userForId m[1] 
        user = null
        for item in users
          if item.id==m[1]
            user=item
            break;
        if user!=undefined and user!=null and user_name != user.name
          replaceText = '@'+user.name
        else
          replaceText =""        
      else if m[3] != undefined
        if user_name != m[3]
          replaceText = '@'+m[3]
        else
          replaceText =""   

      # robot.logger.debug user
      text = text.replace /<@([\w\d]+)(\|([\w]+))?>/ig, replaceText
    robot.logger.info(text)
    dateString = moment.unix(message.ts).format("MM/DD/YYYY HH:mm:SS")
    
    
    entity = "#{dateString} #{user_name} #{text}\r\n"
    result += entity
    if message.attachments
      _.each message.attachments ,(att)->
        if att.fields != null && att.fields != undefined
          k=1
          col=""
          for field in att.fields
            if k%2==1
              col += "\t * #{field.title}: #{field.value}\t\t"
            else
              col +="\t\t#{field.title}: #{field.value}\r\n"              
              result += col
              col="";
            k++
    result += "----------------------\r\n"
    return result
  helpAttach = [
    "Please use the correct syntax: 'sm attach-conversation incident [ID]' to attach channel converstaion to Service Manager Incident",
    "To learn more about all supported commands, enter 'sm'."
  ]
  helpSm = [
    "Use 'sm' to access Service Manager. Enter the following command for a list of available commands for the Service Manager Incident Management module:",
    "'sm incident'"
  ]

  helpIncident = [
    "Please use the following commands to access the Service Manager Incident Management module:",
    "* `sm get incident [ID]` - Retrieve the details of an incident by incident ID (e.g. IM10001)",
    "* `sm assign incident [ID] [person]` - Assign or reassign an incident to a person ([person] can be an email address, SM username, or Slack username)",
    "* `sm resolve incident [ID] \"[solution]\"` - Resolve an incident by providing a solution",
    "* `sm addactivity incident [ID] \"[activity]\"` - Add an activity to an incident",
    "* `sm create incident \"[description]\" -channel` - Create an incident as well as a Slack channel for the new incident (you can omit '-channel' to not create a Slack channel)",
    "* `sm update incident [ID] [field1=value2] [field2=value2]` - Update certain fields of an incident",
    "* `sm attach-conversation incident [ID]` - Attach the entire conversation history of the current channel to an incident"
  ]
  helpWrongCmd = [
    "Wrong command",
    "To learn more about all supported commands, enter 'sm incident'."
  ]
  helpMissPara = [
    "Missing parameter",
    "To learn more about all supported commands, enter 'sm incident'."
  ]
  sendHelp = (resp,channel, msg)->
    resp.send msg.join("\r\n")
      
  getAuthInfo = (b64str)->
    src=new Buffer(b64str, 'base64').toString('utf8')
    [user, pwd] = src.split(":")
    data =
      username:user
      password:pwd
    return data
    
  helpUnknown = ["Invalid command.", "To learn more about all supported commands, enter 'sm'."]
   
  robot.respond /(.*)$/i, (resp)->
    room = resp.message.room
    fullLine = resp.match[1]
    robot.logger.debug "get message:"+fullLine;
    match = /sm(.*)$/i.exec fullLine
    if not match
      resp.send helpUnknown.join("\r\n");
      return
    cmdline = match[1].trim()
    robot.logger.debug "To respond #{cmdline} in room #{room}"
    [verb, entity,para1] = cmdline.split(/\s+/)
    # in case sm incident
    if verb == 'incident'
      resp.send helpIncident.join("\r\n");
      return
    if entity != 'incident'
      # print sm help
      resp.send helpSm.join("\r\n");
      return
    if  not(verb in verbs) 
      resp.send helpWrongCmd.join("\r\n");
      return
    if not para1
      resp.send helpMissPara.join("\r\n");
      return
    robot.logger.debug fullLine+" is a known command";
    
