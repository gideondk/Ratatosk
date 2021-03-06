/*
 * WLRemoteLink.j
 * Ratatosk
 *
 * Created by Alexander Ljungberg on November 25, 2009.
 * Copyright 2009-11, WireLoad Inc. All rights reserved.
 *
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer. Redistributions in binary
 * form must reproduce the above copyright notice, this list of conditions and
 * the following disclaimer in the documentation and/or other materials provided
 * with the distribution. Neither the name of WireLoad Inc. nor the names
 * of its contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

var SharedWLRemoteLink      = nil,
    DefaultBaseUrl          = '/api/',
    WLRemoteLinkRetryDelay  = 10; // in seconds

WLRemoteLinkStateNormal                 = 0;
WLRemoteLinkStateAuthenticationError    = 1;
WLRemoteLinkStateRequestFailureError    = 2;

WLLoginActionDidSucceedNotification     = "WLLoginDidSucceedNotification";
WLLoginActionDidFailNotification        = "WLLoginDidFailNotification";

/*!
    A link to the server side API where the RemoteObjects live. WLRemoteLink does the following:

    * enqueues actions and performs them sequentially
    * receives responses
    * detects errors and retries actions
    * detects expired authentication
    * works together with RemoteObject to collect multiple `PUT` operations into single ones
    * allows special error state actions to run with priority

    Queued actions are executed strictly in order to allow for actions to be
    scheduled for objects which don't have PKs yet. E.g. you could enqueue an
    action to POST an object A and then another to PUT an update to A. When the
    POST finishes you receive the server side PK/URI for the new object and in the
    `PUT` action's `remoteActionWillBegin` you can set the correct URI to `put` to.
    The sequential nature of the queue means the POST has gone before the PUT.

    Special "in error state" actions can move to the top of the queue during error
    states. This allows 'session timed out' errors to be rectified with an action
    which restores the session, after which any other scheduled actions will proceed
    like normal.
*/
@implementation WLRemoteLink : CPObject
{
    CPArray     actionQueue;
    CPString    baseUrl @accessors;
    int         updateDelay;
    CPTimer     updateDelayTimer;
    CPTimer     retryTimer;
    BOOL        isDelayingAction;

    CPDate      lastSuccessfulSave @accessors;

    BOOL        shouldFlushActions @accessors;
    BOOL        hasSaveActions @accessors;

    BOOL        isAuthenticated @accessors;
    BOOL        _retryOneAction;
    int         state @accessors;

    BOOL        useURLAuthentication @accessors;
    CPString    authenticationToken @accessors;
    CPString    authorizationHeader @accessors;
}

+ (void)setDefaultBaseURL:(CPString)anApiUrl
{
    DefaultBaseUrl = anApiUrl;
}

/*!
    Returns the singleton instance of the WLRemoteLink.
*/
+ (WLRemoteLink)sharedRemoteLink
{
    if (!SharedWLRemoteLink)
        SharedWLRemoteLink = [[WLRemoteLink alloc] init];

    return SharedWLRemoteLink;
}

+ (CPSet)keyPathsForValuesAffectingIsInErrorState
{
    return [CPSet setWithObjects:"state"];
}

- (void)init
{
    if (self = [super init])
    {
        state = 0;
        // Optimistically assume we're authenticated initially.
        isAuthenticated = YES;
        _retryOneAction = NO;
        lastSuccessfulSave = [CPDate date];
        shouldFlushActions = NO;
        actionQueue = [];
        baseUrl = DefaultBaseUrl;
        useURLAuthentication = NO;
    }

    return self;
}

- (BOOL)isSecure
{
    var url = [CPURL URLWithString:baseUrl];
    return [url scheme] == 'https';
}

/*!
    Return true if the remote link is broken for any reason other than
    not being authenticated.
*/
- (BOOL)isInErrorState
{
    return state == WLRemoteLinkStateRequestFailureError;
}

- (CPString)urlWithSslIffNeeded:(CPString)aUrl
{
    if (!aUrl)
        return aUrl;

    if ([self isSecure])
        return aUrl.replace(new RegExp('^http:', 'i'), 'https:');
    else
        return aUrl.replace(new RegExp('^https:', 'i'), 'http:');
}

/*!
    If the only action in the queue is a WLRemoteActionPutType, it will be
    delayed up to aDelay seconds before being executed.

    setUpdateDelay in combination with WLRemoteObject's policy to only keep one
    save in the queue at any time enables multiple save operations, e.g. for
    each character the user types, to be collected into single operations at
    aDelay second intervals.
*/
- (void)setUpdateDelay:(int)aDelay
{
    updateDelay = aDelay;
}

- (void)scheduleAction:(WLRemoteAction)action
{
    // CPLog.info("Remote op scheduled: " + [action description]);
    var i = [actionQueue count],
        indexes = [CPIndexSet indexSetWithIndex:i];
    [self willChange:CPKeyValueChangeInsertion valuesAtIndexes:indexes forKey:"actionQueue"];
    [actionQueue addObject:action];
    [self didChange:CPKeyValueChangeInsertion valuesAtIndexes:indexes forKey:"actionQueue"];

    if ([action isSaveAction])
        [self setHasSaveActions:YES];

    //CPLog.info("Action queue: " + actionQueue);

    // Limit the rate of actions to make sure the browser gets a chance to refresh
    // the UI. This probably only really matters when running against localhost but
    // it doesn't harm the general case that much.
    window.setTimeout(function() {
        [self maybeExecute];
    }, 0.3);
}

- (void)unscheduleAction:(WLRemoteAction)anAction
{
    var i = [actionQueue indexOfObject:anAction];
    if (i == CPNotFound)
    {
        CPLog.warn("Unschedule unscheduled action "+anAction);
        return;
    }

    var indexes = [CPIndexSet indexSetWithIndex:i];
    [self willChange:CPKeyValueChangeInsertion valuesAtIndexes:indexes forKey:"actionQueue"];
    [actionQueue removeObject:anAction];
    [self didChange:CPKeyValueChangeInsertion valuesAtIndexes:indexes forKey:"actionQueue"];

    if ([anAction isSaveAction])
        [self _updateHasSaveActions];
}

- (void)setState:(int)aState
{
    if (state === aState)
        return;
    state = aState;

    // Maybe excute regardless of flag: there could be an 'error' action if YES, and if NO
    // a previously blocked action may be startable.
    [self maybeExecute];
}

- (void)setHasSaveActions:(BOOL)aFlag
{
    if (hasSaveActions === aFlag)
        return;

    // If we go from having actions to not, then a save just completed.
    // We'll bump it in the opposite case too: if there were no save actions
    // before, we were obviously saved up. We bump so that the 'time since last
    // save' doesn't show 'five hours' even that we are in fact saved up.
    lastSuccessfulSave = [CPDate date];
    hasSaveActions = aFlag;
}

/*!
    When a remote action fails, leave it in queue for a retry.
*/
- (void)remoteActionDidFail:(WLRemoteAction)anAction dueToAuthentication:(BOOL)dueToAuthentication
{
    CPLog.error("Action failed " + anAction);
    // Ready the action for a later retry.
    [anAction reset];

    if (dueToAuthentication)
    {
        [self setState:WLRemoteLinkStateAuthenticationError];
        if (isAuthenticated)
            [self setIsAuthenticated:NO];
    }
    // Don't retry on non-found
    else if ([anAction statusCode] != 404)
    {
        [self setState:WLRemoteLinkStateRequestFailureError];

        // Schedule a retry.
        if ([retryTimer isValid])
            return; // ...but just one scheduled retry at a time is enough.
        retryTimer = [CPTimer scheduledTimerWithTimeInterval:WLRemoteLinkRetryDelay target:self selector:@selector(retry:) userInfo:nil repeats:NO];
    }
}

/*!
    If in an error state, retry the first action in the queue.
*/
- (void)retry:(id)sender
{
    if (state === WLRemoteLinkStateRequestFailureError)
    {
        _retryOneAction = YES;
        [self maybeExecute];
    }
}

- (void)remoteActionDidFinish:(WLRemoteAction)anAction
{
    //CPLog.info("Remote op finished: "+[anAction description]);

    var actionIndex = [actionQueue indexOfObject:anAction];
    if (actionIndex == CPNotFound && ![anAction isLoginAction])
    {
        CPLog.error("Unscheduled action finished");
    }

    if (![anAction shouldRunInErrorState] && ![anAction isLogoutAction])
    {
        // The success of a normal action indicates we're logged in.
        if (!isAuthenticated)
            [self setIsAuthenticated:YES];
    }
    // Any successful action means the link is nominal.
    [self setState:WLRemoteLinkStateNormal];

    if (actionIndex !== CPNotFound && actionQueue[actionIndex] === anAction)
    {
        var indexes = [CPIndexSet indexSetWithIndex:actionIndex];
        [self willChange:CPKeyValueChangeRemoval valuesAtIndexes:indexes forKey:"actionQueue"];
        [actionQueue removeObjectAtIndex:actionIndex];
        [self didChange:CPKeyValueChangeRemoval valuesAtIndexes:indexes forKey:"actionQueue"];
    }

    [self _updateHasSaveActions];

    // CPLog.info("Action queue: "+actionQueue);
    [self maybeExecute];
}

- (void)_updateHasSaveActions
{
    var r = NO;

    for (var i = 0, count = [actionQueue count]; i < count; i++)
    {
        var anotherAction = actionQueue[i];

        if ([anotherAction isSaveAction])
        {
            r = YES;
            break;
        }
    }
    [self setHasSaveActions:r];
}

- (void)maybeExecute
{
    if (actionQueue.length == 0)
    {
        [self setShouldFlushActions:NO];
        return;
    }

    var nextActionIndex = 0;
    if (!_retryOneAction && [self isInErrorState])
    {
        while (nextActionIndex < actionQueue.length && ![actionQueue[nextActionIndex] shouldRunInErrorState])
            nextActionIndex++;

        if (nextActionIndex >= actionQueue.length)
        {
            /*
            There is no action appropriate for the current error state to execute at this time.
            */
            return;
        }
    }
    // This flag is 'used up'.
    _retryOneAction = NO;

    var nextAction = actionQueue[nextActionIndex];
    if ([nextAction isExecuting] || [nextAction isDone])
        return;

    if (!shouldFlushActions && actionQueue.length == 1 && [nextAction type] == WLRemoteActionPutType && updateDelay > 0)
    {
        if (updateDelayTimer === nil)
        {
            [self setIsDelayingAction:YES];
            updateDelayTimer = [CPTimer scheduledTimerWithTimeInterval:updateDelay target:self selector:"_updateWasDelayed" userInfo:nil repeats:NO];
            return;
        }

        if ([updateDelayTimer isValid])
            return;
    }

    if (updateDelayTimer !== nil)
    {
        /*
            We could get here from a) the timer firing or b) entering a
            circumstance where the delay timer is no longer suitable. In both
            cases the timer should be removed.
        */
        [self setIsDelayingAction:NO];
        [updateDelayTimer invalidate];
        updateDelayTimer = nil;
    }

    [nextAction execute];
}

- (void)_updateWasDelayed
{
    // If a timer already exists, a new one will not be created. If the timer is invalid
    // the action will be taken.
    [updateDelayTimer invalidate];
    [self maybeExecute];
}

- (CPArray)actionQueue
{
    return actionQueue;
}

- (void)emptyActionQueue
{
    [actionQueue removeAllObjects];
}

/*!
    Return YES if the next action is being delayed.
*/
- (BOOL)isDelayingAction
{
    return isDelayingAction;
}

- (void)setIsDelayingAction:(BOOL)aFlag
{
    isDelayingAction = aFlag;
}

- (void)setShouldFlushActions:(BOOL)aFlag
{
    if (aFlag === shouldFlushActions)
        return;

    shouldFlushActions = aFlag;
    if (aFlag)
        [self maybeExecute];
}

@end

/*
    @global
    @group WLRemoteActionType
*/
WLRemoteActionGetType         = 0;
/*
    @global
    @group WLRemoteActionType
*/
WLRemoteActionPostType        = 1;
/*
    @global
    @group WLRemoteActionType
*/
WLRemoteActionPutType         = 2;
/*
    @global
    @group WLRemoteActionType
*/
WLRemoteActionDeleteType      = 3;

/*
For a later potential bitmask optimization.

var WLRemoteActionDelegate_remoteAction_willBegin             = 1 << 0,
    WLRemoteActionDelegate_remoteAction_didFinish             = 1 << 1;
*/

var WLRemoteActionTypeNames = ["GET", "POST", "PUT", "DELETE"],

    WLRemoteActionSerial = 1;

@implementation WLRemoteAction : CPObject
{
    id                  _delegate;
    long                serial;
    BOOL                done;

    CPURLConnection     connection;

    WLRemoteActionType  type @accessors;
    CPString            path @accessors;
    CPDictionary        payload @accessors;

    BOOL                shouldRunInErrorState @accessors;

    BOOL                _didCallWillBegin;

    int                 statusCode @accessors;
    JSObject            result @accessors;
    CPString            message @accessors;
    CPString            error;
}

+ (WLRemoteAction)schedule:(WLRemoteActionType)aType path:(CPString)aPath delegate:(id)aDelegate message:(CPString)aMessage
{
    var action = [[WLRemoteAction alloc] initWithType:aType path:aPath delegate:aDelegate message:aMessage];
    [action schedule];
    return action;
}

+ (CPString)urlEncode:(CPDictionary)data
{
    var keys = [data keyEnumerator],
        r = [[CPArray alloc] init],
        key;

    while (key = [keys nextObject])
    {
        var value = [data objectForKey:key];
        value = value.replace(new RegExp('%', 'g'), '%25');
        value = value.replace(new RegExp('&', 'g'), '%26');
        value = value.replace(new RegExp('=', 'g'), '%3D');
        [r addObject:[CPString stringWithFormat:@"%s=%s", key, value]];
    }
    return r.join("&");
}

- (id)initWithType:(WLRemoteActionType)aType path:(CPString)aPath delegate:(id)aDelegate message:(CPString)aMessage
{
    if (self = [super init])
    {
        serial = WLRemoteActionSerial++;
        shouldRunInErrorState = NO;
        done = NO;
        type = aType;
        path = aPath;
        message = aMessage;
        payload = nil;
        [self setDelegate:aDelegate];
    }

    return self;
}

- (void)schedule
{
    [[WLRemoteLink sharedRemoteLink] scheduleAction:self];
}

- (void)cancel
{
    done = YES;
    [[WLRemoteLink sharedRemoteLink] unscheduleAction:self];
}

- (void)setDelegate:(id)aDelegate
{
    if (_delegate === aDelegate)
        return;

    _delegate = aDelegate;
}

- (void)execute
{
    if (!_didCallWillBegin && [_delegate respondsToSelector:@selector(remoteActionWillBegin:)])
    {
        [_delegate remoteActionWillBegin:self];
    }
    _didCallWillBegin = YES;

    [self makeRequest];
}

- (BOOL)isStarted
{
    return [self isExecuting] || [self isDone];
}

- (BOOL)isExecuting
{
    return connection != nil;
}

- (BOOL)isDone
{
    return done;
}

- (BOOL)isSaveAction
{
    return type !== WLRemoteActionGetType;
}

/*!
    Return true if this action causes the link to become authenticated.
*/
- (BOOL)isLoginAction
{
    return NO;
}

/*!
    Return true if success for this action indicates the user is no longer authenticated.
*/
- (BOOL)isLogoutAction
{
    return NO;
}

/*!
    Reset the action so that it can be retried. This message is sent after an action fails due to
    a network or a server error and will need to be performed a second time.
*/
- (void)reset
{
    connection = nil;
    done = NO;
}

- (void)makeRequest
{
    CPLog.info("makeRequest: " + self);
    if (connection || done)
    {
        CPLog.error("Action fired twice without reset.");
        return;
    }
    var request = [CPURLRequest requestWithURL:[self fullPath]];

    [request setHTTPMethod:WLRemoteActionTypeNames[type]];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    if (type == WLRemoteActionPostType || type == WLRemoteActionPutType)
    {
        [request setValue:"application/json" forHTTPHeaderField:@"Content-Type"];

        if (payload)
        {
            var convertedPayload = payload;
            if (payload.isa && [payload isKindOfClass:CPDictionary])
            {
                convertedPayload = {};
                var keyEnumerator = [payload keyEnumerator],
                    key;
                while (key = [keyEnumerator nextObject])
                {
                    var value = [payload objectForKey:key];
                    convertedPayload[key] = value;
                }
            }

            try
            {
                [request setHTTPBody:[CPString JSONFromObject:convertedPayload]];
            }
            catch(err)
            {
                // This indicates JSON.stringify failed on the given object.
                CPLog.error("Failed to convert payload: " + convertedPayload);
                CPLog.error(err);
                if (typeof(console) !== 'undefined')
                    console.log(convertedPayload);
                [CPException raise:CPInvalidArgumentException reason:"Invalid entry payload."];
            }
        }
    }

    var authorizationHeader = [[WLRemoteLink sharedRemoteLink] authorizationHeader];
    if (authorizationHeader)
        [request setValue:authorizationHeader forHTTPHeaderField:@"Authorization"];

    connection = [CPURLConnection connectionWithRequest:request delegate:self];
    connection._isLocalFileConnection = false;
}

- (void)connection:(CPURLConnection)aConnection didReceiveResponse:(CPURLResponse)aResponse
{
    [self setStatusCode:200];

    if ([aResponse class] == CPHTTPURLResponse)
    {
        var code = [aResponse statusCode];
        if (code < 200 || code > 299)
        {
            [self setStatusCode:code];
            CPLog.error("Received error code " + code);
        }
    }

    if ([_delegate respondsToSelector:@selector(remoteAction:didReceiveResponse:)])
    {
        [_delegate remoteAction:self didReceiveResponse:aResponse];
    }
}

- (void)connection:(CPURLConnection)aConnection didReceiveData:(CPString)data
{
    if (done)
    {
        CPLog.error("Action received data twice");
        return;
    }

    result = nil;
    error = [self statusCode];
    error = error >= 200 && error <= 299 ? nil : error; // 2XX codes are not errors.

    if (error === 0)
    {
        // Sometimes we get code 0 back. Often this means there was no response, e.g.
        // no connection could be made. Simulate a 503 error in that case.
        error = [aConnection _HTTPRequest].success() ? 200 : 503;
    }

    if (type !== WLRemoteActionPutType && type !== WLRemoteActionDeleteType)
    {
        if (data)
        {
            try
            {
                result = [data objectFromJSON];
            }
            catch(err)
            {
                CPLog.error("Got invalid JSON in response.");
                error = 500;
            }

            if (error == 500)
            {
                // Pass
            }
            else if (typeof result === 'undefined' || result === null)
            {
                CPLog.error("Got empty response.");
                error = 500;
            }
            else if (typeof result["error"] !== 'undefined')
            {
                if (result["error"] == 401)
                {
                    // Login needed.
                    error = 401;
                } else {
                    CPLog.error("Got error: " + result["error"] + ": " + result["message"]);
                    error = 500;
                }
            }
        }
        else
        {
            CPLog.error("No data in response.");
            error = 500;
        }
    }
    else
    {
        if (data != "" && data != " " && data != "OK" && data != "{}")
        {
            result = (data ? [data objectFromJSON] : null);

            if (typeof result !== 'undefined' && result !== null && typeof result["error"] !== 'undefined' && result["error"] == 401)
            {
                // Login needed.
                error = 401;
            }
            else
            {
                if (type !== WLRemoteActionPutType)
                {
                    CPLog.error("Unexpected data: "+ data);
                    error = 500;
                }
            }
        }
    }

    [self finish];
}

- (void)connection:(CPURLConnection)aConnection didFailWithError:(CPString)anError
{
    error = anError;

    [self finish];
}

- (void)finish
{
    connection = nil;

    if (error)
    {
        if (error == 401)
        {
            [[WLRemoteLink sharedRemoteLink] remoteActionDidFail:self dueToAuthentication:YES];
        }
        else
        {
            if (error !== 500 && error !== 503)
                CPLog.error("Connection did fail with unknown error: " + error);

            [[WLRemoteLink sharedRemoteLink] remoteActionDidFail:self dueToAuthentication:NO];
        }
        return;
    }

    done = YES;

    if ([_delegate respondsToSelector:@selector(remoteActionDidFinish:)])
    {
        [_delegate remoteActionDidFinish:self];
    }

    [[WLRemoteLink sharedRemoteLink] remoteActionDidFinish:self];
}

- (CPString)fullPath
{
    urlAuthenticationToken = "";

    if ([[WLRemoteLink sharedRemoteLink] useURLAuthentication])
    {
        if (path.indexOf("?") == -1)
            urlAuthenticationToken = "?auth_token=" + [[WLRemoteLink sharedRemoteLink] authenticationToken];
        else
            urlAuthenticationToken = "&auth_token=" + [[WLRemoteLink sharedRemoteLink] authenticationToken];
    }
    var baseUrl = [[WLRemoteLink sharedRemoteLink] baseUrl];
    if (path)
        return baseUrl + path + urlAuthenticationToken;
    else
        return baseUrl + urlAuthenticationToken;
}

- (CPString)description
{
    return "<WLRemoteAction " + serial + " " + WLRemoteActionTypeNames[type] + " " + [self fullPath] + " " + payload + ">";
}

@end


