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
