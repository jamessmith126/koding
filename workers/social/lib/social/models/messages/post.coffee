jraphical = require 'jraphical'

JAccount = require '../account'
JComment = require './comment'

JTag = require '../tag'
CActivity = require '../activity'
CRepliesActivity = require '../activity/repliesactivity'

KodingError = require '../../error'

module.exports = class JPost extends jraphical.Message

  @trait __dirname, '../../traits/followable'
  @trait __dirname, '../../traits/taggable'
  @trait __dirname, '../../traits/notifying'
  @trait __dirname, '../../traits/flaggable'
  @trait __dirname, '../../traits/likeable'
  @trait __dirname, '../../traits/protected'
  @trait __dirname, '../../traits/slugifiable'
  @trait __dirname, '../../traits/restrictedquery'

  {Base,ObjectRef,dash,daisy} = require 'bongo'
  {Relationship} = jraphical
  {extend} = require 'underscore'

  {log} = console

  Validators = require '../group/validators'
  {permit}   = require '../group/permissionset'

  schema = extend {}, jraphical.Message.schema, {
    isLowQuality  : Boolean
    slug          : String
    slug_         : String # this is necessary, because $exists operator won't work with a sparse index.
    group         : String 
    counts        :
      followers   :
        type      : Number
        default   : 0
      following   :
        type      : Number
        default   : 0
  }

  # TODO: these relationships may not be abstract enough to belong to JPost.
  @set
    softDelete  : yes
    slugifyFrom : 'title'
    slugTemplate: ->
      """
      #{if @group is 'koding' then '' else "#{@group}/"}Activity/\#{slug}
      """
    indexes     :
      slug      : 'unique'
      group     : 'sparse'
    permissions :
      'read posts'        : ['member', 'moderator']
      'create posts'      : ['member', 'moderator']
      'edit posts'        : ['moderator']
      'delete posts'      : ['moderator']
      'edit own posts'    : ['member', 'moderator']
      'delete own posts'  : ['member', 'moderator']
      'reply to posts'    : ['member', 'moderator']
      'like posts'        : ['member', 'moderator']
      'follow posts'      : ['guest', 'member', 'moderator']
    emitFollowingActivities: yes
    taggedContentRole : 'post'
    tagRole           : 'tag'
    sharedMethods     :
      static          : ['create','one','updateAllSlugs']
      instance        : [
        'reply','restComments','commentsByRange'
        'like','fetchLikedByes','mark','unmark','fetchTags'
        'delete','modify','fetchRelativeComments','checkIfLikedBefore'
      ]
    schema            : schema
    relationships     :
      comment         : JComment
      participant     :
        targetType    : JAccount
        as            : ['author','commenter']
      likedBy         :
        targetType    : JAccount
        as            : 'like'
      repliesActivity :
        targetType    : CRepliesActivity
        as            : 'repliesActivity'
      tag             :
        targetType    : JTag
        as            : 'tag'
      follower        :
        targetType    : JAccount
        as            : 'follower'

  @getAuthorType =-> JAccount

  @getActivityType =-> CActivity

  @getFlagRole =-> ['sender', 'recipient']

  createKodingError =(err)->
    if 'string' is typeof err
      kodingErr = message: err
    else
      kodingErr = message: err.message
      for own prop of err
        kodingErr[prop] = err[prop]
    kodingErr

  @create = permit 'create posts',
    success: (client, data, callback)->
      constructor = @
      {connection:{delegate}} = client
      unless delegate instanceof constructor.getAuthorType() # TODO: rethink/improve
        callback new Error 'Access denied!'
      else
        if data?.meta?.tags
          {tags} = data.meta
          delete data.meta.tags
        data.group = client.groupName
        status = new constructor data
        # TODO: emit an event, and move this (maybe)
        activity = new (constructor.getActivityType())

        if delegate.checkFlag 'exempt'
          status.isLowQuality   = yes
          activity.isLowQuality = yes

        activity.originId   = delegate.getId()
        activity.originType = delegate.constructor.name
        activity.group      = client.groupName
        teaser              = null

        daisy queue = [
          ->
            status.createSlug (err, slug)->
              if err
                callback err
              else
                status.slug   = slug.slug
                status.slug_  = slug.slug
                queue.next()
          ->
            status
              .sign(delegate)
              .save (err)->
                if err
                  callback err
                else queue.next()
          ->
            delegate.addContent status, (err)-> queue.next(err)
          ->
            activity.save (err)->
              if err
                callback createKodingError err
              else queue.next()
          ->
            activity.addSubject status, (err)->
              if err
                callback createKodingError err
              else queue.next()
          ->
            delegate.addContent activity, (err)-> queue.next(err)
          ->
            tags or= []
            status.addTags client, tags, (err)->
              if err
                log err
                callback createKodingError err
              else
                queue.next()
          ->
            status.fetchTeaser (err, teaser_)=>
              if err
                callback createKodingError err
              else
                teaser = teaser_
                queue.next()
          ->
            activity.update
              $set:
                snapshot: JSON.stringify(teaser)
              $addToSet:
                snapshotIds: status.getId()
            , ->
              callback null, teaser
              CActivity.emit "ActivityIsCreated", activity
              queue.next()
          ->
            status.addParticipant delegate, 'author'
        ]

  constructor:->
    super
    @notifyOriginWhen 'ReplyIsAdded', 'LikeIsAdded'
    @notifyFollowersWhen 'ReplyIsAdded'

  modify: permit
    advanced: [
      { permission: 'edit own posts', validateWith: Validators.own }
      { permission: 'edit posts' }
    ]
    success: (client, formData, callback)->
      {tags} = formData.meta if formData.meta?
      delete formData.meta
      daisy queue = [
        =>
          tags or= []
          @addTags client, tags, (err)=>
            if err
              callback err
            else
              queue.next()
        =>
          @update $set: formData, callback
      ]

  delete: permit
    advanced: [
      { permission: 'delete own posts', validateWith: Validators.own }
      { permission: 'delete posts' }
    ]
    success: ({connection:{delegate}}, callback)->
      id                = @getId()
      createdAt         = @meta.createdAt
      {getDeleteHelper} = Relationship
      queue = [
        getDeleteHelper {
          targetId    : id
          sourceName  : /Activity$/
        }, 'source', -> queue.fin()
        getDeleteHelper {
          sourceId    : id
          sourceName  : 'JComment'
        }, 'target', -> queue.fin()
        ->
          Relationship.remove {
            targetId  : id
            as        : 'post'
          }, -> queue.fin()
        => @remove -> queue.fin()
      ]
      dash queue, =>
        callback null
        @emit 'PostIsDeleted', 1
        CActivity.emit "PostIsDeleted", {
          teaserId : id
          createdAt
          group    : @group
        }

  fetchActivityId:(callback)->
    Relationship.one {
      targetId    : @getId()
      sourceName  : /Activity$/
    }, (err, rel)->
      if err
        callback err
      else unless rel
        callback createKodingError 'No activity found'
      else
        callback null, rel.getAt 'sourceId'

  fetchActivity:(callback)->
    @fetchActivityId (err, id)->
      if err
        callback err
      else
        CActivity.one _id: id, callback

  flushSnapshot:(removedSnapshotIds, callback)->
    removedSnapshotIds = [removedSnapshotIds] unless Array.isArray removedSnapshotIds
    teaser = null
    activityId = null
    queue = [
      =>
        @fetchActivityId (err, activityId_)->
          activityId = activityId_
          queue.next()
      =>
        @fetchTeaser (err, teaser_)=>
          if err
            callback createKodingError err
          else
            teaser = teaser_
            queue.next()
      ->
        CActivity.update _id: activityId, {
          $set:
            snapshot              : JSON.stringify teaser
            'sorts.repliesCount'  : teaser.repliesCount
          $pullAll:
            snapshotIds: removedSnapshotIds
        }, -> queue.next()
      callback
    ]
    daisy queue

  updateSnapshot:(callback)->
    teaser = null
    activityId = null
    queue = [
      =>
        @fetchActivityId (err, activityId_)->
          activityId = activityId_
          queue.next()
      =>
        @fetchTeaser (err, teaser_)->
          return callback createKodingError err if err
          teaser = teaser_
          queue.next()
      =>
        CActivity.update _id: activityId, {
          $set:
            snapshot              : JSON.stringify teaser
            'sorts.repliesCount'  : teaser.repliesCount
          $addToSet:
            snapshotIds: @getId()
        }, -> queue.next()
      callback
    ]
    daisy queue

  removeReply:(rel, callback)->
    id = @getId()
    teaser = null
    activityId = null
    repliesCount = @getAt 'repliesCount'
    queue = [
      -> rel.update $set: 'data.deletedAt': new Date, -> queue.next()
      => @update $inc: repliesCount: -1, -> queue.next()
      => @flushSnapshot rel.getAt('targetId'), -> queue.next()
      callback
    ]
    daisy queue

  reply: permit 'reply to posts',
    success:(client, replyType, comment, callback)->
      {delegate} = client.connection
      unless delegate instanceof JAccount
        callback new Error 'Log in required!'
      else
        comment = new replyType body: comment
        exempt = delegate.checkFlag('exempt')
        if exempt
          comment.isLowQuality = yes
        comment
          .sign(delegate)
          .save (err)=>
            if err
              callback err
            else
              delegate.addContent comment, (err)->
                if err
                  log 'error adding content to delegate with err', err
              @addComment comment,
                flags:
                  isLowQuality    : exempt
              , (err, docs)=>
                if err
                  callback err
                else
                  if exempt
                    callback null, comment
                  else
                    Relationship.count {
                      sourceId                    : @getId()
                      as                          : 'reply'
                      'data.flags.isLowQuality'   : $ne: yes
                    }, (err, count)=>
                      if err
                        callback err
                      else
                        @update $set: repliesCount: count, (err)=>
                          if err
                            callback err
                          else
                            callback null, comment
                            @fetchActivityId (err, id)->
                              CActivity.update {_id: id}, {
                                $set: 'sorts.repliesCount': count
                              }, (err)-> log err if err
                            @fetchOrigin (err, origin)=>
                              if err
                                console.log "Couldn't fetch the origin"
                              else
                                unless exempt
                                  @emit 'ReplyIsAdded', {
                                    origin
                                    subject       : ObjectRef(@).data
                                    actorType     : 'replier'
                                    actionType    : 'reply'
                                    replier       : ObjectRef(delegate).data
                                    reply         : ObjectRef(comment).data
                                    repliesCount  : count
                                    relationship  : docs[0]
                                  }
                                @follow client, emitActivity: no, (err)->
                                @addParticipant delegate, 'commenter', (err)-> #TODO: what should we do with this error?

  # TODO: the following is not well-factored.  It is not abstract enough to belong to "Post".
  # for the sake of expedience, I'll leave it as-is for the time being.
  fetchTeaser:(callback, showIsLowQuality=no)->
    query =
      targetName  : 'JComment'
      as          : 'reply'
      'data.deletedAt':
        $exists   : no

    query['data.flags.isLowQuality'] = $ne: yes unless showIsLowQuality

    @beginGraphlet()
      .edges
        query         : query
        limit         : 3
        sort          :
          timestamp   : -1
      .reverse()
      .and()
      .edges
        query         :
          targetName  : 'JTag'
          as          : 'tag'
        limit         : 5
      .nodes()
    .endGraphlet()
    .fetchRoot callback

  fetchRelativeComments:({limit, before, after}, callback)->
    limit ?= 10
    if before? and after?
      callback createKodingError "Don't use before and after together."
    selector = timestamp:
      if before? then  $lt: before
      else if after? then $gt: after
    selector['data.flags.isLowQuality'] = $ne: yes
    options = {limit, sort: timestamp: 1}
    @fetchComments selector, options, callback

  commentsByRange:(options, callback)->
    [callback, options] = [options, callback] unless callback
    {from, to} = options
    from or= 0
    if from > 1e6
      selector = timestamp:
        $gte: new Date from
        $lte: to or new Date
      queryOptions = {}
    else
      to or= Math.max()
      selector = {}
      queryOptions = skip: from
      if to
        queryOptions.limit = to - from
    selector['data.flags.isLowQuality'] = $ne: yes
    queryOptions.sort = timestamp: -1
    @fetchComments selector, queryOptions, callback

  restComments:(skipCount, callback)->
    [callback, skipCount] = [skipCount, callback] unless callback
    skipCount ?= 3
    @fetchComments {
      'data.flags.isLowQuality': $ne: yes
    },
      skip: skipCount
      sort: { timestamp: 1 }
    , (err, comments)->
      if err
        callback err
      else
        # comments.reverse()
        callback null, comments

  save:->
    delete @data.replies #TODO: this hack should not be necessary...  but it is for some reason.
    # in any case, it should be resolved permanently once we implement Model#prune
    super

  triggerCache:->
    CActivity.emit "PostIsUpdated",
      teaserId  : @getId()
      group     : @group
      createdAt : @meta.createdAt

  update:(rest..., callback)->
    kallback =(rest...)=>
      callback rest...
      @triggerCache()

    jraphical.Message::update.apply @, rest.concat kallback

  makeGroupSelector =(group)->
    if Array.isArray group then $in: group else group

  @update$ = permit 'edit posts',
    success:(client, selector, operation, options, callback)->
      selector.group = makeGroupSelector client.context.group
      @update selector, operation, options, callback

  @one$ = permit 'read posts',
    success:(client, uniqueSelector, options, callback)->
      # TODO: this needs more security?
      uniqueSelector.group = makeGroupSelector client.context.group
      @one uniqueSelector, options, callback

  @all$ = permit 'read posts',
    success:(client, selector, callback)->
      selector.group = client.context.group
      @all selector, callback

  @remove$ = permit 'delete posts',
    success:(client, selector, callback)->
      selector.group = client.context.group
      @remove selector, callback

  @removeById$ = permit 'delete posts',
    success:(client, _id, callback)->
      selector = {
        _id, group : makeGroupSelector client.context.group
      }
      @remove selector, callback

  @count$ = permit 'read posts',
    success:(client, selector, callback)->
      [callback, selector] = [selector, callback]  unless callback
      selector ?= {}
      selector.group = makeGroupSelector client.context.group
      @count selector, callback

  @some$ = permit 'read posts',
    success:(client, selector, options, callback)->
      selector.group = makeGroupSelector client.context.group
      @some selector, options, callback

  @someData$ = permit 'read posts',
    success:(client, selector, options, fields, callback)->
      selector.group = makeGroupSelector client.context.group
      @someData selector, options, fields, callback

  @cursor$ = permit 'read posts',
    success:(client, selector, options, callback)->
      selector.group = makeGroupSelector client.context.group
      @cursor selector, options, callback

  @each$ = permit 'read posts',
    success:(client, selector, fields, options, callback)->
      selector.group = makeGroupSelector client.context.group
      @each selector, fields, options, callback

  @hose$ = permit 'read posts',
    success:(client, selector, rest...)->
      selector.group = makeGroupSelector client.context.group
      @someData selector, rest...

  @teasers$ = permit 'read posts',
    success:(client, selector, options, callback)->
      selector.group = makeGroupSelector client.context.group
      @teasers selector, options, callback
