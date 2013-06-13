JBundle = require '../bundle'

module.exports = class JGroupBundle extends JBundle

  KodingError = require '../../error'

  {permit} = require '../group/permissionset'

  {groupBy} = require 'underscore'

  {daisy} = require 'bongo'

  @share()

  @trait __dirname, '../../traits/protected'

  @set
    sharedEvents      :
      static          : []
      instance        : []
    sharedMethods     :
      static          : []
      instance        : []
    permissions       :
      'manage payment methods'  : []
      'change bundle'           : []
      'request bundle change'   : ['member','moderator']
      'commission resources'    : ['member','moderator']
    schema            :
      overagePolicy   :
        type          : String
        enum          : [
          'unknown value for overage'
          ['allowed', 'by permission', 'not allowed']
        ]
        default       : 'not allowed'

  createVM: (account, group, data, callback)->
    JRecurlyPlan         = require '../recurly'
    JRecurlySubscription = require '../recurly/subscription'
    JVM                  = require '../vm'
    async                = require 'async'

    {type, planCode} = data

    if type is 'user'
      planOwner = "user_#{account._id}"
    else if type is 'group'
      planOwner = "group_#{group._id}"
    else if type is 'expensed'
      planOwner = "group_#{group._id}"

    JRecurlySubscription.all
      userCode: planOwner
      planCode: planCode
      status  : 'active'
    , (err, subs)=>
      return callback new KodingError "Payment backend error: #{err}"  if err

      expensed = type is "expensed"

      paidVMs     = 0
      expensedVMs = 0
      subs.forEach (sub)->
        if sub.status is 'active' and sub.planCode is planCode
          paidVMs = sub.quantity
          if type is 'expensed'
            expensedVMs = sub.expensed
          else if type is 'group'
            paidVMs    -= sub.expensed

      if expensed
        paidVMs = expensedVMs

      createdVMs = 0
      JVM.someData
        planOwner: planOwner
        planCode : planCode
        expensed : expensed
      ,
        name     : 1
      , {}, (err, cursor)=>
        cursor.toArray (err, arr)=>
          return callback err  if err
          arr.forEach (vm)->
            createdVMs += 1

          # TODO: Also check user quota here

          if paidVMs > createdVMs
            options     =
              planCode  : planCode
              usage     : {cpu: 1, ram: 1, disk: 1}
              type      : type
              account   : account
              groupSlug : group.slug
              expensed  : expensed
            JVM.createVm options, ->
              callback null, planCode
          else
            callback new KodingError "Can't create new VM."

  checkUsage: (account, group, callback)->
    JVM = require '../vm'
    JVM.someData
      planOwner   : "group_#{group._id}"
      expensedUser: "user_#{account._id}"
      expensed    : yes
    ,
      name        : 1
      planCode    : 1
    , {}, (err, cursor)=>
      cursor.toArray (err, arr)=>
        callback err, arr