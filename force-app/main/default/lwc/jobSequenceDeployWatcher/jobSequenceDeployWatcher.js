/**
 * Copyright 2026 Gary Butler
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
/**
 * @description jobSequenceDeployWatcher -- Waits for the result of a Sequence Job save. Saves are asynchronous Apex
 * metadata deployments; JobSequenceDeployCallback publishes each result as a Job Sequencer Deploy Result platform
 * event, which this module receives through the Emp API and hands to whoever is waiting for that deployment.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { subscribe, onError } from 'lightning/empApi';

const CHANNEL = '/event/Job_Sequencer_Deploy_Result__e';
const DEFAULT_TIMEOUT_MS = 120000;

let subscriptionPromise;
const waiters = new Map();
// Results that arrived before anyone started waiting (a fast deploy can finish before the Apex call returns)
const earlyResults = new Map();

/**
 * @description Normalizes a deployment Id to 15 characters so 15- and 18-character Ids match.
 * @param {String} id The deployment Id
 * @returns {String} The 15-character key
 */
function keyFor(id) {
    return (id || '').substring(0, 15);
}

/**
 * @description Routes a platform event to the matching waiter, or keeps it until one arrives.
 * @param {Object} message The Emp API message
 */
function handleMessage(message) {
    const payload = message?.data?.payload || {};
    const key = keyFor(payload.DeploymentId__c);
    const result = { status: payload.Status__c, message: payload.Message__c };
    const waiter = waiters.get(key);
    if (waiter) {
        clearTimeout(waiter.timer);
        waiters.delete(key);
        waiter.resolve(result);
    } else {
        earlyResults.set(key, result);
    }
}

/**
 * @description Subscribes to the deploy result channel once per page. Call this before starting a save.
 * @returns {Promise} Resolves when the subscription is active
 */
export function ensureSubscribed() {
    if (!subscriptionPromise) {
        onError(() => {
            subscriptionPromise = undefined;
        });
        subscriptionPromise = subscribe(CHANNEL, -1, handleMessage);
    }
    return subscriptionPromise;
}

/**
 * @description Waits for a deployment's result.
 * @param {String} deploymentId The Id returned by the save
 * @param {Number} timeoutMs How long to wait before giving up
 * @returns {Promise<Object>} Resolves with { status, message }; status is 'Timeout' when no result arrived in time
 */
export function waitForDeployment(deploymentId, timeoutMs = DEFAULT_TIMEOUT_MS) {
    const key = keyFor(deploymentId);
    if (earlyResults.has(key)) {
        const result = earlyResults.get(key);
        earlyResults.delete(key);
        return Promise.resolve(result);
    }
    return new Promise((resolve) => {
        const timer = setTimeout(() => {
            waiters.delete(key);
            resolve({ status: 'Timeout' });
        }, timeoutMs);
        waiters.set(key, { resolve, timer });
    });
}
