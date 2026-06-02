let currentTab = "All";
let currentDeviceTab = "blocked";
let activeApprovalType = "T";
let selectedTTL = 300;
let allDevices = [];
let allRules = [];
let activeTimers = [];
let currentDetailData = null;
let currentFingerprint = null;

document.addEventListener('DOMContentLoaded', () => {
    reloadData();
    setInterval(reloadData, 10000);
    setInterval(updateCountdowns, 1000);
});

function reloadData() {
    fetchStatus();
    fetchDevices();
    fetchRules();
    fetchLogs();
}

// ─── System Status ──────────────────────────────────────────────
function fetchStatus() {
    fetch('/api/status')
        .then(res => res.json())
        .then(data => {
            const daemonBadge = document.getElementById('daemon-badge');
            if (data.daemon_active) {
                daemonBadge.className = "status-badge status-active";
                daemonBadge.innerHTML = '<i class="fa-solid fa-power-off"></i> Daemon: Running';
            } else {
                daemonBadge.className = "status-badge status-inactive";
                daemonBadge.innerHTML = '<i class="fa-solid fa-power-off"></i> Daemon: Stopped';
            }

            const reaperBadge = document.getElementById('reaper-badge');
            if (data.timer_active) {
                reaperBadge.className = "status-badge status-active";
                reaperBadge.innerHTML = '<i class="fa-regular fa-clock"></i> Reaper: Active';
            } else {
                reaperBadge.className = "status-badge status-inactive";
                reaperBadge.innerHTML = '<i class="fa-regular fa-clock"></i> Reaper: Inactive';
            }

            document.getElementById('stat-allowed').innerText = data.active_rules_count || 0;
        })
        .catch(err => console.error("Error fetching status:", err));
}

// ─── Devices ────────────────────────────────────────────────────
function fetchDevices() {
    fetch('/api/devices')
        .then(res => res.json())
        .then(data => {
            allDevices = data;
            renderDevicesList();
        })
        .catch(err => {
            document.getElementById('blocked-devices-list').innerHTML = `
                <div class="empty-state">
                    <i class="fa-solid fa-triangle-exclamation empty-icon" style="color:var(--danger)"></i>
                    <p style="color:var(--danger)">IPC channel did not respond. Verify USBGuard daemon status.</p>
                </div>`;
        });
}

function renderDevicesList() {
    const listContainer = document.getElementById('blocked-devices-list');
    const blockedCountBadge = document.getElementById('blocked-count-badge');
    listContainer.innerHTML = '';

    const blockedDevices = allDevices.filter(d => d.status === 'block');
    document.getElementById('stat-blocked').innerText = blockedDevices.length;

    if (blockedDevices.length > 0) {
        blockedCountBadge.style.display = 'block';
        blockedCountBadge.innerText = `${blockedDevices.length} BLOCKED`;
    } else {
        blockedCountBadge.style.display = 'none';
    }

    const targetDevices = allDevices.filter(d => 
        currentDeviceTab === 'blocked' ? d.status === 'block' : d.status === 'allow'
    );

    if (targetDevices.length === 0) {
        listContainer.innerHTML = `
            <div class="empty-state">
                <i class="fa-solid fa-circle-check empty-icon" style="color:var(--success); opacity:0.3;"></i>
                <p>No ${currentDeviceTab} USB devices connected.</p>
            </div>`;
        return;
    }

    targetDevices.forEach(dev => {
        const avatarClass = dev.status === 'block' ? 'avatar-blocked' : 'avatar-allowed';
        const badgeClass = dev.status === 'block' ? 'badge-blocked' : 'badge-allowed';

        const itemHTML = `
            <div class="device-item" onclick="openInspector('${dev.id}', 'device', '${dev.device_id}')">
                <div class="device-meta">
                    <div class="device-avatar ${avatarClass}">
                        <i class="fa-solid fa-usb"></i>
                    </div>
                    <div class="device-details">
                        <h4>${dev.name || 'Generic USB Device'}</h4>
                        <div class="device-sub">
                            <span><i class="fa-solid fa-tag"></i> ID: ${dev.id}</span>
                            <span><i class="fa-solid fa-circle-info"></i> Port: ${dev.port}</span>
                            <span><span class="badge ${badgeClass}">${dev.status}</span></span>
                        </div>
                    </div>
                </div>
                <i class="fa-solid fa-angle-right" style="color:var(--text-secondary)"></i>
            </div>`;
        listContainer.innerHTML += itemHTML;
    });
}

function switchDeviceTab(tabType, el) {
    currentDeviceTab = tabType;

    document.getElementById('tab-dev-blocked').classList.remove('active');
    document.getElementById('tab-dev-allowed').classList.remove('active');
    el.classList.add('active');

    renderDevicesList();
}

// ─── Rules ──────────────────────────────────────────────────────
function fetchRules() {
    fetch('/api/rules')
        .then(res => res.json())
        .then(data => {
            allRules = data;
            const tempRules = allRules.filter(r => r.category === 'Temporary');
            document.getElementById('stat-temporary').innerText = tempRules.length;
            renderRulesList();
        })
        .catch(err => console.error("Error fetching rules:", err));
}

function renderRulesList() {
    const listContainer = document.getElementById('active-rules-list');
    listContainer.innerHTML = '';

    const filteredRules = currentTab === "All" 
        ? allRules 
        : allRules.filter(r => r.category === currentTab);

    if (filteredRules.length === 0) {
        listContainer.innerHTML = `
            <div class="empty-state">
                <i class="fa-solid fa-scale-balanced empty-icon"></i>
                <p>No active rules configured in this category.</p>
            </div>`;
        return;
    }

    activeTimers = [];

    filteredRules.forEach((rule, idx) => {
        let expiryHTML = '';
        let progressHTML = '';
        let fingerprintIndicator = '';

        if (rule.category === 'Temporary' && rule.ttl_epoch) {
            const epochNow = Math.floor(Date.now() / 1000);
            const remainingSec = rule.ttl_epoch - epochNow;

            if (remainingSec > 0) {
                const timerId = `countdown-timer-${idx}`;
                const progressId = `countdown-progress-${idx}`;
                expiryHTML = `<span id="${timerId}" class="countdown-span" style="font-size: 0.75rem; color: var(--warning); margin-left: 0.5rem;" data-expiry="${rule.ttl_epoch}"><i class="fa-solid fa-stopwatch"></i> Calculating...</span>`;

                progressHTML = `
                    <div class="expiry-progress-container" style="display:block;">
                        <div id="${progressId}" class="expiry-progress-bar"></div>
                    </div>`;

                activeTimers.push({
                    timerId: timerId,
                    progressId: progressId,
                    expiry: rule.ttl_epoch,
                    total: 3600
                });
            } else {
                expiryHTML = `<span style="font-size: 0.75rem; color: var(--danger); margin-left: 0.5rem;"><i class="fa-solid fa-stopwatch"></i> Expired</span>`;
            }
        }

        // Show fingerprint icon if stored
        if (rule.fingerprint) {
            fingerprintIndicator = `<i class="fa-solid fa-fingerprint" style="color: var(--info); font-size: 0.75rem; margin-left: 0.3rem;" title="Device fingerprinted"></i>`;
        }

        const itemHTML = `
            <div class="rule-item" onclick="openInspector('${rule.id}', 'rule')">
                <div style="width: 100%;">
                    <div style="display: flex; justify-content: space-between; align-items: center;">
                        <div class="device-meta">
                            <div class="device-details">
                                <h4 style="font-size: 0.95rem;">${rule.name || 'System Authorization Block'} ${fingerprintIndicator}</h4>
                                <div class="device-sub">
                                    <span><i class="fa-solid fa-microchip"></i> ID: ${rule.id || 'system'}</span>
                                    <span><i class="fa-solid fa-file-code"></i> File: ${rule.filename}</span>
                                    ${expiryHTML}
                                </div>
                            </div>
                        </div>
                        <span class="rule-category-badge cat-${rule.category}">${rule.category}</span>
                    </div>
                    ${progressHTML}
                </div>
            </div>`;
        listContainer.innerHTML += itemHTML;
    });

    updateCountdowns();
}

function updateCountdowns() {
    const epochNow = Math.floor(Date.now() / 1000);

    activeTimers.forEach(t => {
        const el = document.getElementById(t.timerId);
        const prg = document.getElementById(t.progressId);
        if (!el) return;

        const remaining = t.expiry - epochNow;
        if (remaining > 0) {
            const hours = Math.floor(remaining / 3600);
            const mins = Math.floor((remaining % 3600) / 60);
            const secs = remaining % 60;

            let timerStr = "";
            if (hours > 0) timerStr += `${hours}h `;
            if (mins > 0 || hours > 0) timerStr += `${mins}m `;
            timerStr += `${secs}s`;

            el.innerHTML = `<i class="fa-solid fa-stopwatch"></i> Expires in ${timerStr}`;

            if (prg) {
                const percent = Math.max(0, Math.min(100, (remaining / t.total) * 100));
                prg.style.width = `${percent}%`;

                if (percent < 15) {
                    prg.style.background = 'var(--danger)';
                    el.style.color = 'var(--danger)';
                } else if (percent < 50) {
                    prg.style.background = 'var(--warning)';
                    el.style.color = 'var(--warning)';
                } else {
                    prg.style.background = 'linear-gradient(to right, var(--primary), var(--info))';
                }
            }
        } else {
            el.innerHTML = `<i class="fa-solid fa-stopwatch"></i> Expired`;
            if (prg) prg.style.width = '0%';
        }
    });
}

function switchTab(tabName, el) {
    currentTab = tabName;
    const tabs = document.querySelectorAll('.tab-btn');
    tabs.forEach(t => t.classList.remove('active'));
    el.classList.add('active');
    renderRulesList();
}

// ─── Logs ───────────────────────────────────────────────────────
function fetchLogs() {
    fetch('/api/logs')
        .then(res => res.json())
        .then(data => {
            const logsContainer = document.getElementById('console-logs');
            if (data.error) {
                logsContainer.innerHTML = `<div class="console-line" style="color:var(--danger)">Error: ${data.error}</div>`;
                return;
            }
            logsContainer.innerHTML = '';
            data.logs.forEach(log => {
                let color = '#10b981';
                if (log.includes('[ERROR]') || log.includes('[CRITICAL]')) {
                    color = '#ef4444';
                } else if (log.includes('[WARN]')) {
                    color = '#f59e0b';
                } else if (log.includes('[AUDIT]')) {
                    color = '#06b6d4';
                }
                logsContainer.innerHTML += `<div class="console-line" style="color: ${color}">${log}</div>`;
            });
            logsContainer.scrollTop = logsContainer.scrollHeight;
        })
        .catch(err => console.error("Error fetching logs:", err));
}

// ─── Inspector / Drawer ────────────────────────────────────────
function openInspector(deviceVidPid, mode, deviceId) {
    let deviceData = null;
    let ruleData = null;

    deviceData = allDevices.find(d => d.id === deviceVidPid);
    ruleData = allRules.find(r => r.id === deviceVidPid);

    if (!deviceData && !ruleData) {
        console.error("Device ID mismatch:", deviceVidPid);
        return;
    }

    const name = deviceData ? deviceData.name : ruleData.name;
    const status = deviceData ? deviceData.status : (ruleData.category === 'Temporary' ? 'Temporary' : 'Allowed');
    const serial = deviceData ? deviceData.serial : ruleData.serial;
    const devHash = deviceData ? deviceData.hash : ruleData.hash;
    const parentHash = deviceData ? deviceData.parent_hash : 'N/A';
    const port = deviceData ? deviceData.port : 'N/A';
    const interfaces = deviceData ? deviceData.interfaces : ruleData.interfaces;
    const devId = deviceData ? deviceData.device_id : '';

    document.getElementById('inspector-name').innerText = name || 'USB Device Block';
    document.getElementById('inspector-id').innerText = deviceVidPid;
    document.getElementById('inspector-serial').innerText = serial || 'N/A';
    document.getElementById('inspector-port').innerText = port;
    document.getElementById('inspector-hash').innerText = devHash || 'N/A';
    document.getElementById('inspector-parent').innerText = parentHash;
    document.getElementById('inspector-interfaces').innerText = interfaces || 'N/A';

    // Store VID:PID and Device ID for actions
    document.getElementById('inspector-device-id').value = devId;
    document.getElementById('inspector-vid-pid').value = deviceVidPid;

    // Status badge and avatar
    const statusBadge = document.getElementById('inspector-status-badge');
    const avatarDiv = document.getElementById('inspector-avatar');

    if (status === 'block') {
        statusBadge.className = "badge badge-blocked";
        statusBadge.innerText = "Blocked";
        avatarDiv.className = "device-avatar avatar-blocked";
        document.getElementById('inspector-controls-section').style.display = 'block';
        document.getElementById('btn-save-auth').style.display = 'flex';
        document.getElementById('btn-save-auth').innerHTML = '<i class="fa-solid fa-shield-halved"></i> Authorize Connection';
        document.getElementById('btn-block-now').style.display = 'none';
    } else {
        statusBadge.className = "badge badge-allowed";
        statusBadge.innerText = ruleData && ruleData.category === 'Temporary' ? "Temporary Link" : "Authorized";
        avatarDiv.className = "device-avatar avatar-allowed";
        document.getElementById('inspector-controls-section').style.display = 'block';
        document.getElementById('btn-save-auth').style.display = 'flex';
        document.getElementById('btn-save-auth').innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update Status';
        document.getElementById('btn-block-now').style.display = 'flex';
    }

    // Populate type selector
    if (ruleData && ruleData.category === 'Temporary') {
        selectApprovalType('T');
        if (ruleData.ttl_epoch) {
            const epochNow = Math.floor(Date.now() / 1000);
            const remaining = ruleData.ttl_epoch - epochNow;
            if (remaining > 0) {
                document.getElementById('drawer-ttl-seconds').value = remaining;
            }
        }
    } else if (ruleData && ruleData.category === 'Permanent') {
        selectApprovalType('P');
    } else {
        selectApprovalType('T');
    }

    // Store fingerprint from rule if exists
    currentFingerprint = ruleData ? ruleData.fingerprint : null;

    // Reset lsusb detail section to loading
    document.getElementById('detail-section').style.display = 'none';
    document.getElementById('detail-loading').style.display = 'block';
    document.getElementById('detail-content').innerHTML = '';

    // Reset fingerprint section
    const fpSection = document.getElementById('fingerprint-section');
    fpSection.style.display = 'block';
    fpSection.innerHTML = `
        <div class="fingerprint-verdict no-scan">
            <i class="fa-solid fa-fingerprint"></i> Scanning device...
        </div>`;
    document.getElementById('btn-block-now').style.display = status !== 'block' ? 'flex' : 'none';

    // Open drawer immediately
    document.getElementById('inspector-overlay').classList.add('active');

    // Fetch lsusb detail and fingerprint asynchronously
    fetchDeviceDetail(deviceVidPid);
}

function fetchDeviceDetail(vidPid) {
    fetch(`/api/device-detail?id=${vidPid}`)
        .then(res => res.json())
        .then(data => {
            if (data.error) {
                document.getElementById('detail-loading').style.display = 'none';
                document.getElementById('detail-content').innerHTML = `
                    <div style="color: var(--warning); font-size: 0.85rem; padding: 1rem; text-align: center;">
                        <i class="fa-solid fa-triangle-exclamation"></i> ${data.error}
                        <br><small style="color: var(--text-secondary);">${data.note || ''}</small>
                    </div>`;
                document.getElementById('detail-section').style.display = 'block';
                
                // Show no-scan for fingerprint too
                document.getElementById('fingerprint-section').innerHTML = `
                    <div class="fingerprint-verdict no-scan">
                        <i class="fa-solid fa-fingerprint"></i> Cannot scan device. It may not be connected.
                    </div>`;
                return;
            }

            currentDetailData = data;
            const fp = data.fingerprint || {};
            const parsed = data.parsed || {};

            // Render the detailed lsusb info
            renderDeviceDetail(data);

            // Check fingerprint vs stored
            checkFingerprint(vidPid, fp, currentFingerprint);
        })
        .catch(err => {
            console.error("Error fetching device detail:", err);
            document.getElementById('detail-loading').style.display = 'none';
            document.getElementById('detail-content').innerHTML = `
                <div style="color: var(--danger); padding: 1rem; text-align: center;">
                    <i class="fa-solid fa-bug"></i> Failed to load device details
                </div>`;
        });
}

function renderDeviceDetail(data) {
    const parsed = data.parsed || {};
    const device = parsed.device || {};
    const config = parsed.configuration || {};
    const interfaces = parsed.interfaces || [];
    const endpoints = parsed.endpoints || [];
    const busInfo = parsed.bus_info || {};

    document.getElementById('detail-loading').style.display = 'none';
    document.getElementById('detail-content').style.display = 'block';

    let html = '';

    // Bus Information
    if (busInfo.bus) {
        html += `
            <div class="detail-table-section">
                <h6>Bus & Connection</h6>
                <div class="property-sheet">
                    <div class="prop-row">
                        <div class="prop-name">Bus Address</div>
                        <div class="prop-value">Bus ${busInfo.bus} Device ${busInfo.device}</div>
                    </div>
                    <div class="prop-row">
                        <div class="prop-name">Description</div>
                        <div class="prop-value">${busInfo.description || 'N/A'}</div>
                    </div>
                </div>
            </div>`;
    }

    // USB Specs
    html += `
        <div class="detail-table-section">
            <h6>USB Specification</h6>
            <div class="property-sheet">
                <div class="prop-row">
                    <div class="prop-name">USB Version</div>
                    <div class="prop-value">${device.bcdUSB || 'N/A'}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">Device Class</div>
                    <div class="prop-value">${device.bDeviceClass || 'N/A'} ${device.bDeviceSubClass || ''}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">Max Packet Size</div>
                    <div class="prop-value">${device.bMaxPacketSize0 || 'N/A'}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">Max Power</div>
                    <div class="prop-value">${config.MaxPower || 'N/A'} ${config.power_type ? '(' + config.power_type + ')' : ''}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">Device Status</div>
                    <div class="prop-value">${parsed.status || 'N/A'}</div>
                </div>
            </div>
        </div>`;

    // Manufacturer & Identity
    html += `
        <div class="detail-table-section">
            <h6>Manufacturer & Identity</h6>
            <div class="property-sheet">
                <div class="prop-row">
                    <div class="prop-name">Manufacturer</div>
                    <div class="prop-value">${device.iManufacturer || 'N/A'}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">Product</div>
                    <div class="prop-value">${device.iProduct || 'N/A'}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">Serial</div>
                    <div class="prop-value" style="font-family: monospace; word-break: break-all;">${device.iSerial || 'N/A'}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">Vendor ID</div>
                    <div class="prop-value">${device.idVendor || 'N/A'}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">Product ID</div>
                    <div class="prop-value">${device.idProduct || 'N/A'}</div>
                </div>
                <div class="prop-row">
                    <div class="prop-name">BCD Device</div>
                    <div class="prop-value">${device.bcdDevice || 'N/A'}</div>
                </div>
            </div>
        </div>`;

    // Interfaces
    if (interfaces.length > 0) {
        html += `
            <div class="detail-table-section">
                <h6>Interface Descriptors (${interfaces.length})</h6>
                <div class="property-sheet">`;
        interfaces.forEach((iface, i) => {
            const d = iface.descriptors || {};
            html += `
                <div class="prop-row" style="flex-wrap: wrap;">
                    <div class="prop-name">Interface ${i}</div>
                    <div class="prop-value">
                        Class: ${d.bInterfaceClass || 'N/A'} | SubClass: ${d.bInterfaceSubClass || 'N/A'} | Protocol: ${d.bInterfaceProtocol || 'N/A'}
                    </div>
                </div>`;
        });
        html += `</div></div>`;
    }

    // Endpoints
    if (endpoints.length > 0) {
        html += `
            <div class="detail-table-section">
                <h6>Endpoints (${endpoints.length})</h6>
                <table class="endpoint-table">
                    <thead>
                        <tr>
                            <th>#</th>
                            <th>Address</th>
                            <th>Type</th>
                            <th>Max Packet</th>
                            <th>Interval</th>
                        </tr>
                    </thead>
                    <tbody>`;
        endpoints.forEach((ep, i) => {
            const d = ep.descriptors || {};
            const addr = d.bEndpointAddress || '';
            const type = d['Transfer Type'] || d.bmAttributes || '';
            const pkt = d.wMaxPacketSize || '';
            const interval = d.bInterval || '';
            html += `
                <tr>
                    <td>${i}</td>
                    <td>${addr}</td>
                    <td>${type}</td>
                    <td>${pkt}</td>
                    <td>${interval}</td>
                </tr>`;
        });
        html += `</tbody></table></div>`;
    }

    // Raw data toggle
    html += `
        <div class="detail-table-section">
            <h6>Raw Output</h6>
            <div style="background: rgba(1, 3, 7, 0.4); border-radius: 8px; padding: 0.75rem; font-family: monospace; font-size: 0.65rem; color: var(--text-secondary); max-height: 150px; overflow-y: auto; white-space: pre-wrap; word-break: break-all;">${escapeHtml(parsed.raw || '')}</div>
        </div>`;

    document.getElementById('detail-content').innerHTML = html;
    document.getElementById('detail-section').style.display = 'block';
}

function checkFingerprint(vidPid, currentFp, storedFp) {
    const fpSection = document.getElementById('fingerprint-section');
    
    if (!storedFp) {
        // No stored fingerprint - offer to save
        fpSection.innerHTML = `
            <div class="fingerprint-verdict no-scan">
                <i class="fa-solid fa-fingerprint"></i> No fingerprint stored for this device
            </div>
            <div style="display: flex; gap: 0.5rem;">
                <button class="btn-fingerprint" onclick="saveFingerprint('${vidPid}')" style="flex: 1;">
                    <i class="fa-solid fa-floppy-disk"></i> Save Current Fingerprint
                </button>
                <button class="btn-fingerprint" onclick="verifyFingerprint('${vidPid}')" style="flex: 1;">
                    <i class="fa-solid fa-rotate"></i> Scan Again
                </button>
            </div>`;
        return;
    }

    // Verify against stored
    fpSection.innerHTML = `
        <div class="fingerprint-verdict no-scan">
            <i class="fa-solid fa-fingerprint"></i> Verifying fingerprint...
        </div>`;

    fetch('/api/verify-fingerprint', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            vid_pid: vidPid,
            stored_fingerprint: storedFp
        })
    })
    .then(res => res.json())
    .then(data => {
        if (data.error) {
            fpSection.innerHTML = `
                <div class="fingerprint-verdict no-scan">
                    <i class="fa-solid fa-triangle-exclamation"></i> ${data.error}
                </div>`;
            return;
        }

        let verdictClass = 'no-scan';
        let verdictIcon = 'fa-circle-question';
        
        switch (data.verdict) {
            case 'TRUSTED':
                verdictClass = 'trusted';
                verdictIcon = 'fa-shield-halved';
                break;
            case 'SUSPICIOUS':
                verdictClass = 'suspicious';
                verdictIcon = 'fa-triangle-exclamation';
                break;
            case 'DANGEROUS':
                verdictClass = 'dangerous';
                verdictIcon = 'fa-circle-exclamation';
                break;
        }

        let html = `
            <div class="fingerprint-verdict ${verdictClass}">
                <i class="fa-solid ${verdictIcon}"></i> ${data.verdict}: ${data.match_percentage}% match
            </div>
            <div style="margin-bottom: 0.75rem;">
                <div style="display: flex; justify-content: space-between; align-items: center; font-size: 0.8rem;">
                    <span style="color: var(--text-secondary);">Match: <strong style="color: ${data.match_percentage >= 80 ? 'var(--success)' : data.match_percentage >= 50 ? 'var(--warning)' : 'var(--danger)'}">${data.match_percentage}%</strong></span>
                    <span style="color: var(--text-secondary);">${data.matches}/${data.total_fields} fields matched</span>
                </div>
                <div style="height: 4px; background: rgba(255,255,255,0.05); border-radius: 4px; margin-top: 0.3rem; overflow: hidden;">
                    <div style="height: 100%; width: ${data.match_percentage}%; background: ${data.match_percentage >= 80 ? 'var(--success)' : data.match_percentage >= 50 ? 'var(--warning)' : 'var(--danger)'}; border-radius: 4px;"></div>
                </div>
            </div>`;

        // Show mismatches
        if (data.mismatches && data.mismatches.length > 0) {
            html += `<div style="font-size: 0.75rem; color: var(--danger); margin-bottom: 0.5rem;">⚠ ${data.mismatches.length} field(s) differed:</div>`;
            data.mismatches.forEach(m => {
                html += `
                    <div class="fingerprint-mismatch">
                        <span class="field-name">${m.field}</span>
                        <span class="field-values">"${m.stored}" → "${m.current}"</span>
                    </div>`;
            });
        }

        html += `
            <div style="font-size: 0.75rem; color: var(--text-secondary); margin-top: 0.5rem;">
                <i class="fa-regular fa-circle-info"></i> ${data.message}
            </div>
            <div style="display: flex; gap: 0.5rem; margin-top: 0.75rem;">
                <button class="btn-fingerprint" onclick="saveFingerprint('${vidPid}')" style="flex: 1;">
                    <i class="fa-solid fa-floppy-disk"></i> Update Fingerprint
                </button>
                <button class="btn-fingerprint" onclick="verifyFingerprint('${vidPid}')" style="flex: 1;">
                    <i class="fa-solid fa-rotate"></i> Rescan
                </button>
            </div>`;

        fpSection.innerHTML = html;
    })
    .catch(err => {
        fpSection.innerHTML = `
            <div class="fingerprint-verdict no-scan">
                <i class="fa-solid fa-bug"></i> Fingerprint verification failed
            </div>`;
    });
}

function saveFingerprint(vidPid) {
    // Get the current fingerprint from the detail data
    if (!currentDetailData || !currentDetailData.fingerprint) {
        alert("No fingerprint data available to save. Try scanning again.");
        return;
    }

    const fp = currentDetailData.fingerprint;
    
    // Find the button that was clicked
    const buttons = document.querySelectorAll('#fingerprint-section .btn-fingerprint');
    const btn = buttons[0];
    if (!btn) return;
    
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Saving...';

    // Save by calling approve with fingerprint
    const deviceId = document.getElementById('inspector-device-id').value;
    const type = activeApprovalType;
    const ttl = document.getElementById('drawer-ttl-seconds').value;

    // Check if rule already exists
    const ruleExists = allRules.some(r => r.id === vidPid);
    
    if (ruleExists) {
        // Just update fingerprint in the rule file directly
        fetch('/api/approve', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                device_id: deviceId || null,
                vid_pid: vidPid,
                type: type,
                ttl: type === 'T' ? ttl : null,
                fingerprint: fp
            })
        })
        .then(res => res.json())
        .then(data => {
            btn.disabled = false;
            btn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Save Current Fingerprint';
            if (data.success) {
                reloadData();
                setTimeout(() => verifyFingerprint(vidPid), 500);
            } else {
                alert(`Error saving fingerprint: ${data.error || 'Unknown error'}`);
            }
        })
        .catch(err => {
            btn.disabled = false;
            btn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Save Current Fingerprint';
        });
    } else {
        // Need to approve first
        if (!deviceId) {
            alert("Device must be connected and selected to save fingerprint with authorization.");
            btn.disabled = false;
            btn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Save Current Fingerprint';
            return;
        }

        fetch('/api/approve', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                device_id: deviceId,
                vid_pid: vidPid,
                type: type,
                ttl: type === 'T' ? ttl : null,
                fingerprint: fp
            })
        })
        .then(res => res.json())
        .then(data => {
            btn.disabled = false;
            btn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Save Current Fingerprint';
            if (data.success) {
                closeInspector();
                reloadData();
            } else {
                alert(`Error: ${data.error}`);
            }
        })
        .catch(err => {
            btn.disabled = false;
            btn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Save Current Fingerprint';
        });
    }
}

function verifyFingerprint(vidPid) {
    // Re-scan the device
    currentFingerprint = null;
    document.getElementById('fingerprint-section').innerHTML = `
        <div class="fingerprint-verdict no-scan">
            <i class="fa-solid fa-fingerprint"></i> Scanning device...
        </div>`;
    fetchDeviceDetail(vidPid);
}

function closeInspector() {
    document.getElementById('inspector-overlay').classList.remove('active');
    currentDetailData = null;
    currentFingerprint = null;
}

function handleOutsideClick(event) {
    if (event.target === document.getElementById('inspector-overlay')) {
        closeInspector();
    }
}

function selectApprovalType(type) {
    activeApprovalType = type;

    const cardTemp = document.getElementById('drawer-type-temp');
    const cardPerm = document.getElementById('drawer-type-perm');
    const ttlContainer = document.getElementById('drawer-ttl-options');

    if (type === 'T') {
        cardTemp.classList.add('active');
        cardPerm.classList.remove('active');
        ttlContainer.style.display = 'block';
    } else {
        cardTemp.classList.remove('active');
        cardPerm.classList.add('active');
        ttlContainer.style.display = 'none';
    }
}

function selectTTL(seconds, el) {
    selectedTTL = seconds;
    const buttons = document.querySelectorAll('.preset-btn');
    buttons.forEach(btn => btn.classList.remove('active'));
    if (el) el.classList.add('active');
    document.getElementById('drawer-ttl-seconds').value = seconds;
}

function customTTLChanged() {
    selectedTTL = document.getElementById('drawer-ttl-seconds').value;
    const buttons = document.querySelectorAll('.preset-btn');
    buttons.forEach(btn => btn.classList.remove('active'));
}

function saveAuthorization() {
    const deviceId = document.getElementById('inspector-device-id').value;
    const vidPid = document.getElementById('inspector-vid-pid').value;
    const saveBtn = document.getElementById('btn-save-auth');

    saveBtn.disabled = true;
    saveBtn.innerHTML = '<span class="spinner" style="margin-right: 0.5rem;"></span> Applying...';

    const payload = {
        device_id: deviceId || null,
        vid_pid: vidPid,
        type: activeApprovalType,
        ttl: activeApprovalType === 'T' ? document.getElementById('drawer-ttl-seconds').value : null,
        fingerprint: currentDetailData ? currentDetailData.fingerprint : null
    };

    const ruleExists = allRules.some(r => r.id === vidPid);
    const endpoint = ruleExists ? '/api/change-status' : '/api/approve';

    fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    })
    .then(res => res.json())
    .then(data => {
        saveBtn.disabled = false;
        saveBtn.innerHTML = '<i class="fa-solid fa-shield-halved"></i> Apply Authorization';

        if (data.success) {
            closeInspector();
            reloadData();
        } else {
            alert(`Error: ${data.error}`);
        }
    })
    .catch(err => {
        saveBtn.disabled = false;
        saveBtn.innerHTML = '<i class="fa-solid fa-shield-halved"></i> Apply Authorization';
        alert(`Network error: ${err}`);
    });
}

function blockDeviceImmediately() {
    const deviceId = document.getElementById('inspector-device-id').value;
    const vidPid = document.getElementById('inspector-vid-pid').value;
    const blockBtn = document.getElementById('btn-block-now');

    if (!confirm(`Are you sure you want to immediately BLOCK and revoke access for device ${vidPid}?`)) {
        return;
    }

    blockBtn.disabled = true;
    blockBtn.innerHTML = '<span class="spinner" style="margin-right: 0.5rem;"></span> Revoking...';

    fetch('/api/block', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            device_id: deviceId || null,
            vid_pid: vidPid
        })
    })
    .then(res => res.json())
    .then(data => {
        blockBtn.disabled = false;
        blockBtn.innerHTML = '<i class="fa-solid fa-circle-minus"></i> Block Immediately (Revoke Access)';

        if (data.success) {
            closeInspector();
            reloadData();
        } else {
            alert(`Error: ${data.error}`);
        }
    })
    .catch(err => {
        blockBtn.disabled = false;
        blockBtn.innerHTML = '<i class="fa-solid fa-circle-minus"></i> Block Immediately (Revoke Access)';
        alert(`Network error: ${err}`);
    });
}

function escapeHtml(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
}