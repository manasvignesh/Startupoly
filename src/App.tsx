import React, { Suspense } from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider } from './data/auth';
import { ToastProvider, ErrorBoundary, PixelLoader } from './ui';

// Immediate static imports for Team & Public routes (instant mobile load)
import { LandingPage } from './routes/public/LandingPage';
import { RulesPage } from './routes/public/RulesPage';
import { NotFoundPage } from './routes/public/NotFoundPage';
import { TeamJoinPage } from './routes/team/TeamJoinPage';
import { TeamDashboardPage } from './routes/team/TeamDashboardPage';
import { RequireAdmin } from './routes/admin/RequireAdmin';

import { SceneTransition } from './ui/pixel';

// Route-level code-splitting for Admin pages to keep mobile bundle ultra-light
const AdminLoginPage = React.lazy(() =>
  import('./routes/admin/AdminLoginPage').then((m) => ({ default: m.AdminLoginPage }))
);
const AdminDashboardPage = React.lazy(() =>
  import('./routes/admin/AdminDashboardPage').then((m) => ({ default: m.AdminDashboardPage }))
);
const AdminRoomPage = React.lazy(() =>
  import('./routes/admin/AdminRoomPage').then((m) => ({ default: m.AdminRoomPage }))
);
const AdminHistoryPage = React.lazy(() =>
  import('./routes/admin/AdminHistoryPage').then((m) => ({ default: m.AdminHistoryPage }))
);
const AdminRoomHistoryPage = React.lazy(() =>
  import('./routes/admin/AdminRoomHistoryPage').then((m) => ({ default: m.AdminRoomHistoryPage }))
);

const AppRoutes: React.FC = () => {
  return (
    <SceneTransition>
      <Suspense fallback={<PixelLoader />}>
        <Routes>
          {/* Public Root */}
          <Route path="/" element={<LandingPage />} />
          <Route path="/rules" element={<RulesPage />} />

          {/* Team Routes (Mobile-first, instantly loaded) */}
          <Route path="/join" element={<TeamJoinPage />} />
          <Route path="/team" element={<TeamDashboardPage />} />

          {/* Admin Auth */}
          <Route path="/admin/login" element={<AdminLoginPage />} />

          {/* Protected Admin Routes */}
          <Route path="/admin" element={<RequireAdmin />}>
            <Route index element={<AdminDashboardPage />} />
            <Route path="room/:roomId" element={<AdminRoomPage />} />
            <Route path="history" element={<AdminHistoryPage />} />
            <Route path="history/:roomId" element={<AdminRoomHistoryPage />} />
          </Route>

          {/* Catch-all Not Found */}
          <Route path="/404" element={<NotFoundPage />} />
          <Route path="*" element={<Navigate to="/404" replace />} />
        </Routes>
      </Suspense>
    </SceneTransition>
  );
};

export const App: React.FC = () => {
  return (
    <ErrorBoundary>
      <AuthProvider>
        <ToastProvider>
          <BrowserRouter>
            <AppRoutes />
          </BrowserRouter>
        </ToastProvider>
      </AuthProvider>
    </ErrorBoundary>
  );
};

export default App;
