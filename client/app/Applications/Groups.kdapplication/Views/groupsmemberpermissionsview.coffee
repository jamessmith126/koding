class GroupsMemberPermissionsView extends JView

  constructor:(options = {}, data)->

    options.cssClass = "groups-member-permissions-view"

    super

    @listController = new KDListViewController
      itemClass             : GroupsMemberPermissionsListItemView
      lazyLoadThreshold     : .99
    @listWrapper    = @listController.getView()

    @loader         = new KDLoaderView
      cssClass      : 'loader'
    @loaderText     = new KDView
      partial       : 'Loading Member Permissions…'
      cssClass      : ' loader-text'

    @listController.getListView().on 'ItemWasAdded', (view)=>
      view.on 'RolesChanged', @bound 'memberRolesChange'

    @listController.on 'LazyLoadThresholdReached', @bound 'continueLoadingTeasers'
    @on 'teasersLoaded', =>
      unless @listController.scrollView.hasScrollBars()
        @loader.show()
        @loaderText.show()
        @continueLoadingTeasers()

    @loader.show()
    @loaderText.show()
    @refresh()

  fetchRoles:(callback=->)->
    groupData = @getData()
    list = @listController.getListView()
    list.getOptions().group = groupData
    groupData.fetchRoles (err, roles)=>
      return warn err if err
      list.getOptions().roles = roles

  fetchSomeMembers:(selector={})->
    options =
      limit : 20
      sort  : { timestamp: -1 }
    @getData().fetchMembers selector, options, (err, members)=>
      return warn err if err
      @loader.hide()
      @loaderText.hide()
      @listController.hideLazyLoader()
      if members.length > 0
        ids = (member._id for member in members)
        @getData().fetchUserRoles ids, (err, userRoles)=>
          return warn err if err
          userRolesHash = {}
          for userRole in userRoles
            userRolesHash[userRole.targetId] ?= []
            userRolesHash[userRole.targetId].push userRole.as

          list = @listController.getListView()
          list.getOptions().userRoles ?= []
          list.getOptions().userRoles = _.extend(
            list.getOptions().userRoles, userRolesHash
          )

          @listController.instantiateListItems members
          @timestamp = new Date members.last.timestamp_
          @emit 'teasersLoaded'

  refresh:->
    @listController.removeAllItems()
    @timestamp = new Date 0
    @fetchRoles()
    @fetchSomeMembers()

  continueLoadingTeasers:->
    @fetchSomeMembers {timestamp: $lt: @timestamp.getTime()}

  memberRolesChange:(member, roles)->
    @getData().changeMemberRoles member.getId(), roles, (err)-> console.log {arguments}

  viewAppended:->
    super
    @loader.show()

  pistachio:->
    """
    {{> @loader}}
    {{> @loaderText}}
    {{> @listWrapper}}
    """