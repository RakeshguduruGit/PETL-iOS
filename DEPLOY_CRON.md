# Deploy Vercel Cron Job for Silent Pushes

## 🎯 **What This Does**

Automatically sends silent push notifications every 3 minutes to all devices that are currently charging, enabling:
- Background Live Activity updates
- Unplug detection (within 2-5 minutes)
- Fresh charging analytics

---

## 📋 **Prerequisites**

✅ Vercel environment variables already set:
- `ONESIGNAL_APP_ID`
- `ONESIGNAL_REST_API_KEY`
- `CRON_SECRET`

✅ Files created:
- `/api/cron/send-silent-push.js`
- `/vercel.json`

---

## 🚀 **Deployment Steps**

### **1. Commit the New Files**

```bash
cd /Users/rakeshguduru/Desktop/PETL
git add api/cron/send-silent-push.js vercel.json
git commit -m "Add Vercel cron job for periodic silent pushes"
git push origin main
```

### **2. Deploy to Vercel**

Vercel will automatically:
- Detect the new `vercel.json` cron configuration
- Deploy the cron endpoint
- Start running it every 3 minutes

**Or manually deploy:**
```bash
vercel --prod
```

### **3. Verify Deployment**

Check Vercel dashboard:
1. Go to https://vercel.com/
2. Select your PETL project
3. Go to **Settings** → **Crons**
4. You should see: `send-silent-push` running every 3 minutes

---

## 🧪 **Test the Cron Endpoint**

Before waiting for the scheduled run, test it manually:

```bash
curl -X GET \
  https://your-app.vercel.app/api/cron/send-silent-push \
  -H "Authorization: Bearer YOUR_CRON_SECRET"
```

**Expected response:**
```json
{
  "success": true,
  "timestamp": "2025-10-21T08:45:00.000Z",
  "recipients": 1,
  "notificationId": "abc123..."
}
```

---

## 📊 **Monitor Cron Execution**

### **Vercel Dashboard:**
1. Project → **Deployments** → Click latest
2. **Functions** tab → Find `/api/cron/send-silent-push`
3. Click to see execution logs

### **Expected Logs:**
```
[CRON] Sending silent push to all charging devices...
[CRON] Success: Sent to 1 recipient(s)
```

---

## ⚙️ **Adjust Frequency (Optional)**

Edit `vercel.json` to change how often pushes are sent:

```json
{
  "crons": [
    {
      "path": "/api/cron/send-silent-push",
      "schedule": "*/2 * * * *"   // Every 2 minutes (more responsive)
      // OR
      "schedule": "*/5 * * * *"   // Every 5 minutes (better battery)
    }
  ]
}
```

**Recommended:** Start with 3 minutes, adjust based on:
- User feedback on dismissal timing
- Battery impact reports
- OneSignal delivery metrics

---

## 🎯 **How It Works**

1. **User plugs in device** → App launches → Live Activity appears
2. **User backgrounds app** → iOS suspends it after ~3 minutes
3. **Vercel cron runs** (every 3 min) → Sends silent push
4. **Device receives push** → iOS wakes app in background
5. **App checks battery** → Still charging? Update LA : Dismiss LA
6. **User unplugs** → Next push detects it → LA dismisses

**Result:** Live Activity dismisses within 2-5 minutes of unplugging! 🎉

---

## 🔧 **Troubleshooting**

### **Cron not running?**
- Check Vercel dashboard → Settings → Crons
- Verify `vercel.json` is in project root
- Ensure latest deployment includes the cron config

### **"Unauthorized" errors?**
- Verify `CRON_SECRET` environment variable is set
- Check authorization header matches

### **"Missing OneSignal credentials"?**
- Verify environment variables in Vercel dashboard
- Re-deploy after setting variables

### **No devices receiving pushes?**
- Check OneSignal tags: devices need `charging:true` tag
- Verify devices have opted in to notifications
- Check OneSignal dashboard for delivery status

---

## ✅ **Success Criteria**

Your cron job is working when:
- ✅ Vercel dashboard shows regular executions (every 3 min)
- ✅ OneSignal dashboard shows notifications being sent
- ✅ App logs show `src=bg-push` entries
- ✅ Live Activity dismisses after unplugging (2-5 min)

---

## 🎊 **After Deployment**

Once the cron is running, test the full flow:

1. **Plug in device** → Open PETL → Live Activity appears
2. **Background app** → Lock device
3. **Wait 3+ minutes** → Cron sends first push
4. **Unplug device** → Keep locked
5. **Wait 2-5 minutes** → Live Activity should disappear

**If LA dismisses without opening the app: SUCCESS!** 🚀

---

**Status:** Ready to deploy!  
**Next:** Run the git commands above to deploy to production.

