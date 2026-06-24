// Daemon IPC over DistributedNotificationCenter. Same pattern as
// stroke / facet: `perch daemon --reload` / `daemon --quit` post a notification
// here; the server's `installControlObserver` reacts on the main
// thread.
//
// Notification name is deliberately distinct from the bundle id
// so the bundle id can change without breaking older clients.

import Foundation

public let controlNotificationName = "com.perch.app.control"
public let statusPath = "/tmp/perch.status"
