###

SageMathCloud, Copyright (C) 2015, William Stein

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

---

RethinkDB-backed time-log database-based synchronized editing

[Describe algorithm here]

###

{EventEmitter} = require('events')

uuid_time = require('uuid-time')
node_uuid = require('node-uuid')
diffsync  = require('diffsync')
misc      = require('misc')

# patch that transforms s0 into s1
exports.make_patch = make_patch = (s0, s1) ->
    return diffsync.compress_patch(diffsync.dmp.patch_make(s0, s1))

exports.apply_patch = apply_patch = (patch, s) ->
    x = diffsync.dmp.patch_apply(diffsync.decompress_patch(patch), s)
    clean = true
    for a in x[1]
        if not a
            clean = false
            break
    return [x[0], clean]

apply_patch_sequence = (patches, s) ->
    for x in patches
        s = apply_patch(x.patch, s)[0]
    return s

patch_cmp = (a, b) -> misc.cmp_array([a.time, a.user], [b.time, b.user])

# Sorted list of patches applied to a string
class SortedPatchList
    constructor: (string) ->
        @_patches = []
        @_string = string

    add: (patches) =>
        patches = (x for x in patches when x?)
        # this is O(n*log(n)) where n is the length of @_patches and patches;
        # better would be an insertion sort which would be O(m*log(n)) where m=patches.length...
        @_patches = @_patches.concat(patches)
        @_patches.sort(patch_cmp)

    value: =>
        s = @_string
        for x in @_patches
            s = apply_patch(x.patch, s)[0]
        return s

class SyncString extends EventEmitter
    constructor: (@string_id, @client) ->
        if not @string_id?
            throw Error("must specify string_id")
        if not @client?
            throw Error("must specify client")

        query =
            syncstrings :
                string_id : @string_id
                users     : null
                snapshot  : null
        @_syncstring_table = @client.sync_table(query)

        @_syncstring_table.once 'change', =>
            @_handle_syncstring_update()
            @_syncstring_table.on('change', @_handle_syncstring_update)
            @_patch_list = new SortedPatchList(@_snapshot.string)

            query =
                patches :
                    id    : [@string_id, @_snapshot.time]
                    patch : null
            @_patches_table = @client.sync_table(query)
            @_patches_table.once 'change', =>
                @_patch_list.add(@_get_patches())
                @_last = @_live = @_last_remote = @_remote()
                @_patches_table.on('change', @_handle_patch_update)

    dbg: (f) ->
        return (m...) -> console.log("SyncString.#{f}: ", m...)

    # set or get live version of this synchronized string
    live: (live) =>
        if live?
            @_live = live
        else
            return @_live

    # returns version of string at given point in time
    version: (time) =>
        v = @_get_patches(undefined, time)
        return apply_patch_sequence(v, @_snapshot.string)

    # returns list of timestamps of the the versions of this string
    versions: =>
        m = @_patches_table.get()
        v = []
        m.map (x, id) =>
            key = x.get('id').toJS()
            v.push(key[1])
        v.sort()
        return v

    # close synchronized editing of this string
    close: =>
        @_closed = true
        @_patches_table.close()

    # save any changes we have to the backend
    save: (cb) =>
        dbg = @dbg('save')
        if @_closed
            dbg("string closed -- can't save")
            return
        if not @_live?
            dbg("string not initialized -- can't save")
            return
        dbg("syncing at ", new Date())
        if @_live == @_last
            dbg("nothing changed so nothing to save")
            return
        # compute transformation from last to live -- exactly what we did
        patch = make_patch(@_last, @_live)
        @_last = @_live
        # now save the resulting patch
        time = @client.server_time()
        obj =
            id    : [@string_id, time, @_user_id]
            patch : patch
        dbg('attempting to save patch ', time, JSON.stringify(obj))
        x = @_patches_table.set(obj, 'none', cb)
        @_patch_list.add([@_process_patch(x)])

    # Create and store in the database a snapshot of the state
    # of the string at the given point in time.  This should
    # be the time of an existing patch.
    snapshot: (time, cb) =>
        # Get all the patches up to the given point in time.
        v = @_get_patches(undefined, time)
        if v[v.length-1].time != time
            throw Error("time (=#{misc.to_json(time)}) must be time of an actual patch")
        # compute the new snapshot
        s = apply_patch_sequence(v, @_snapshot.string)
        # save the snapshot in the database
        @_snapshot = {string:s, time:time}
        @_syncstring_table.set({string_id:@string_id, snapshot:@_snapshot}, cb)

    _process_patch: (x, time0, time1) =>
        key = x.get('id').toJS()
        time = key[1]; user = key[2]
        if time < @_snapshot.time
            return
        if time0? and time <= time0
            return
        if time1? and time > time1
            return
        obj =
            time  : time
            user  : user
            patch : x.get('patch').toJS()
        return obj

    # return all patches with time such that time0 < time <= time1;
    # if time0 undefined then sets equal to time of snapshot; if time1 undefined treated as +oo
    _get_patches: (time0, time1) =>
        time0 ?= @_snapshot.time
        m = @_patches_table.get()  # immutable.js map with keys the globally unique patch id's (sha1 of time_id and string_id)
        v = []
        m.map (x, id) =>
            p = @_process_patch(x, time0, time1)
            if p?
                v.push(p)
        v.sort(patch_cmp)
        return v

    # Return the "remote" version of the string, which is what is defined by
    # our view of the current state of the database.   This is
    # the result of applying one after the other all of the patches
    # returned by @_get_patches to the starting string (which is '' for now).
    _remote: =>
        return @_patch_list.value()

    _show_log: =>
        s = @_snapshot.string
        for x in @_get_patches()
            console.log(x.user, x.time, JSON.stringify(x.patch))
            t = apply_patch(x.patch, s)
            s = t[0]
            console.log("   ", t[1], misc.trunc_middle(s,100).trim())

    _handle_syncstring_update: =>
        dbg = @dbg("_handle_syncstring_update")
        x = @_syncstring_table.get_one()?.toJS()
        dbg(JSON.stringify(x))
        # TODO: potential races, but it will (or should!?) get instantly fixed when we get an update in case of a race (?)
        if not x?
            @_snapshot = {string:'', time:0}
            # brand new syncstring
            @_user_id = 0
            @_users = [@client.account_id]
            @_syncstring_table.set({string_id:@string_id, snapshot:@_snapshot, users:@_users})
        else
            @_snapshot = x.snapshot
            @_users    = x.users
            @_user_id = @_users.indexOf(@client.account_id)
            if @_user_id == -1
                @_user_id = @_users.length
                @_users.push(@client.account_id)
                @_syncstring_table.set({string_id:@string_id, users:@_users})

    # update of remote version -- update live as a result.
    _handle_patch_update: (changed_keys) =>
        if not changed_keys?
            # this happens right now when we do a save.
            return
        dbg = @dbg("_handle_patch_update")
        dbg(new Date(), changed_keys)

        if changed_keys?
            @_patch_list.add( (@_process_patch(@_patches_table.get(key)) for key in changed_keys) )

        # save any unsaved changes we have made
        if @_last != @_live
            @save()

        # compute result of applying all patches in order to snapshot
        new_remote = @_remote()
        # if document changed, set live to new version
        if @_live != new_remote
            @emit('change')
            @_last = @_live = new_remote

exports.SyncString = SyncString