// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.PendingIntent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import android.widget.Toast

/**
 * The "Panic off" Quick Settings tile. One tap powers off (or, without
 * the SHUTDOWN permission, restarts) at once, also from the lock screen:
 * like pulling the USB stick out in Tails, it asks nothing first. Only a
 * call, emergency callback mode or a call that ended a short while ago
 * holds it ([CallWatch]); the toast then says why.
 */
class PanicTileService : TileService() {

    override fun onStartListening() {
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            subtitle = getString(
                if (PanicOff.canPowerOff(this@PanicTileService)) R.string.tile_subtitle_poweroff
                else R.string.tile_subtitle_restart,
            )
            updateTile()
        }
    }

    override fun onClick() {
        val problem = PanicOff.trigger(this) { intent ->
            // From a tile, activities start through a PendingIntent.
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE),
            )
        }
        if (problem.isNotEmpty()) {
            Log.w("AntumbraPanic", problem)
            Toast.makeText(this, problem, Toast.LENGTH_LONG).show()
        }
    }
}
